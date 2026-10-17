import Foundation
import Observation

/// One store per API and session: owns the handler chain, both caches and every live instance.
///
/// Views call the store; the store runs requests through the handler chain off the main actor; responses are
/// upserted into the resource cache; the cache updates the `Live` instances views observe.
///
/// Every throwing method of the store and its collections throws `IonError` only, so
/// `catch IonError.cancelled { }` is exhaustive in practice. The signatures say plain `throws` because Swift 6.1
/// crashes at -Onone on typed throws from generic async functions whose result depends on `T` (see CLAUDE.md).
///
/// Usage: `let store = Store(baseURL: url, handlers: [BearerTokenHandler { token }, URLSessionHandler()])`
@MainActor @Observable
public final class Store {
    public let baseURL: URL
    @ObservationIgnored public let codec: ResourceCodec
    /// Decides fresh / stale / expired for cached documents; overridable per store.
    @ObservationIgnored public var cachePolicy: any CachePolicy
    /// How `resolve(_ relationship: ToMany)` fetches ids that are not cached. Default: one `find` per id.
    /// Usage: `store.resolveStrategy = .batched()` for a server that supports `filter[id]=1,2,3`.
    @ObservationIgnored public var resolveStrategy: ResolveStrategy = .oneByOne
    /// Called once per request that failed in the handler chain: a transport error or a non-2xx status the store
    /// does not accept (a 304 to a GET and a 404 to a DELETE are accepted). Covers every request the store sends,
    /// background revalidations and `Fetch` included; never `.cancelled`; the attempts of `RetryHandler` count as
    /// one, and callers sharing an in-flight GET as one. Runs before the error reaches the caller.
    /// Usage: `store.onError = { error, _ in if error.status == 401 { account.signOut() } }`
    @ObservationIgnored public var onError: (@MainActor (IonError, RawRequest) -> Void)?
    /// The transport error of the most recently sent request that finished, or nil once a request sent later got
    /// any HTTP response. Observable, so an "offline" badge can follow it.
    /// Usage: `if store.lastTransportError != nil { OfflineBadge() }`
    public private(set) var lastTransportError: IonError?

    @ObservationIgnored let chain: HandlerChain
    @ObservationIgnored let resources = ResourceCache()
    @ObservationIgnored let requests = RequestCache()
    @ObservationIgnored var inflight: [RequestKey: InFlight] = [:]
    @ObservationIgnored var collections: [RequestKey: WeakCollection] = [:]
    /// Incremented on every successful local mutation; entries remember the value at their last mutation.
    @ObservationIgnored var mutationCounter = 0
    /// When the request that last set or cleared `lastTransportError` was sent; an older one cannot override it.
    @ObservationIgnored private var lastOutcomeSentAt = Date.distantPast
    /// Open `batch` calls; while above zero, `invalidate(type:)` defers collection reloads.
    @ObservationIgnored private var batchDepth = 0
    @ObservationIgnored private var deferredReloadTypes: Set<String> = []

    /// - Parameters:
    ///   - baseURL: resolved against relative request paths.
    ///   - handlers: the chain, last one performing the request. Default: `[URLSessionHandler()]`.
    ///   - codec: key casing and date handling for resource structs.
    ///   - cachePolicy: default `DefaultCachePolicy()` (soft 1 min, hard 24 h, honoring server headers).
    public init(
        baseURL: URL,
        handlers: [any RequestHandler] = [URLSessionHandler()],
        codec: ResourceCodec = .default,
        cachePolicy: any CachePolicy = DefaultCachePolicy()
    ) {
        self.baseURL = baseURL
        self.chain = HandlerChain(handlers)
        self.codec = codec
        self.cachePolicy = cachePolicy
    }

    // MARK: Cache control

    /// Marks every cached query of the type expired and reloads alive collections of it (when `autoRefresh`).
    /// Inside `batch` the reload waits for the batch to end. Call after a push notification, say.
    public func invalidate(type: String) {
        requests.invalidate(type: type)
        guard batchDepth == 0 else {
            deferredReloadTypes.insert(type)
            return
        }
        reloadAliveCollections(ofType: type)
    }

    /// Runs `body` and reloads each alive collection it made stale once, when the outermost batch ends (also when
    /// `body` throws), instead of once per save. Saves and deletes inside still upsert, tombstone, drop deleted
    /// items from lists and mark cached queries stale at once; only the reloads of alive collections wait, and
    /// `autoRefresh` is read when they run. The batch is store-wide: a mutation from another screen while it runs
    /// waits too. Concurrent saves inside `body` (a task group) are fine as long as `body` awaits them.
    ///
    /// Usage: `try await store.batch { for row in rows { var draft = Draft(new: row); try await store.save(&draft) } }`
    public func batch<R>(_ body: @MainActor () async throws -> R) async rethrows -> R {
        batchDepth += 1
        defer {
            batchDepth -= 1
            if batchDepth == 0 { flushDeferredReloads() }
        }
        return try await body()
    }

    private func flushDeferredReloads() {
        let types = deferredReloadTypes.sorted()
        deferredReloadTypes = []
        for type in types {
            reloadAliveCollections(ofType: type)
        }
    }

    private func reloadAliveCollections(ofType type: String) {
        for collection in aliveCollections(ofType: type) where collection.autoRefresh {
            collection.reloadInBackground()
        }
    }

    /// Marks every cached document whose primary data lists the key expired.
    public func invalidate(key: ResourceKey) {
        requests.invalidate(key: key)
    }

    /// Drops every cached resource and document, for logout. Alive collections become empty (`state == .idle`)
    /// until reloaded; a reload running at that moment is cancelled and cannot bring old data back.
    public func clear() {
        resources.removeAll()
        requests.removeAll()
        deferredReloadTypes = []
        for collection in aliveCollections(ofType: nil) {
            collection.reset()
        }
    }

    /// Upserts every resource of a document the app obtained itself (a push payload, test seed data)
    /// without a request. Alive collections are not touched.
    public func upsert(_ document: JSONAPIDocument) {
        for object in document.allObjects {
            resources.upsert(object, codec: codec, startSequence: mutationCounter)
        }
    }

    /// Number of resources in the identity map (tombstones included).
    public var cachedResourceCount: Int { resources.count }

    // MARK: Fetch pipeline

    /// A GET's cache step followed, when needed, by a fetch. Returns the keys of the result. Throws `IonError` only.
    func load<T: Resource>(_ request: Request<JSONAPIDocument>, as type: T.Type) async throws -> CachedDocument {
        let raw = try RawRequest(request, baseURL: baseURL)
        let key = request.cache.key.map(RequestKey.init) ?? raw.key
        if request.method == .get, !request.cache.reload, let entry = requests[key] {
            switch cachePolicy.state(of: entry, now: Date()) {
            case .expired:
                break
            case .stale:
                refetchInBackground(request, raw: raw, key: key, as: T.self)
                return entry
            case .fresh:
                if request.cache.backgroundReload {
                    refetchInBackground(request, raw: raw, key: key, as: T.self)
                }
                return entry
            }
        }
        return try await fetch(request, raw: raw, key: key, as: T.self)
    }

    /// `load` without typed primaries.
    func load(_ request: Request<JSONAPIDocument>) async throws -> CachedDocument {
        try await load(request, as: NoResource.self)
    }

    private func refetchInBackground<T: Resource>(_ request: Request<JSONAPIDocument>, raw: RawRequest, key: RequestKey, as type: T.Type) {
        guard inflight[key] == nil else { return }
        Task { try? await fetch(request, raw: raw, key: key, as: T.self) }
    }

    /// Runs the request (deduplicated with other in-flight GETs of the same key), decodes the primary objects as
    /// `T` off the main actor, then upserts everything and records the document.
    ///
    /// A GET whose cached document has an `ETag` is sent with `If-None-Match`; a 304 refreshes the cached entry
    /// without touching any resource. A caller joins an in-flight GET only when that request started after the
    /// key's last invalidation and no mutation succeeded since, so a load after a save never adopts a response the
    /// server produced before the save.
    func fetch<T: Resource>(_ request: Request<JSONAPIDocument>, raw original: RawRequest, key: RequestKey, as type: T.Type) async throws -> CachedDocument {
        let startSequence = mutationCounter
        var raw = original
        if request.method == .get, let etag = requests[key]?.etag, !raw.hasHeader("If-None-Match") {
            raw.headers["If-None-Match"] = etag
        }
        var fetched: Fetched
        if request.method == .get {
            let flight: InFlight
            var owned = false
            if let existing = inflight[key], canJoin(existing, key: key) {
                flight = existing
            } else {
                let chain = self.chain
                let conditional = raw
                let sentAt = Date()
                let task = Task.detached { try await Store.perform(conditional, chain: chain, sentAt: sentAt) }
                flight = InFlight(task: task, startedAt: sentAt, startSequence: startSequence)
                inflight[key] = flight
                owned = true
            }
            defer { if owned, inflight[key]?.task == flight.task { inflight[key] = nil } }
            do {
                fetched = try await flight.task.value
                if owned { record(nil, for: raw, sentAt: flight.startedAt) }
            } catch {
                let error = IonError(error)
                if owned { record(error, for: raw, sentAt: flight.startedAt) }
                throw error
            }
            if Task.isCancelled { throw IonError.cancelled }
        } else {
            fetched = try await send(raw)
        }
        if fetched.response.status == 304 {
            if let entry = requests[key] {
                let refreshed = entry.revalidated(at: fetched.sentAt, response: fetched.response)
                requests[key] = refreshed
                return refreshed
            }
            // Nothing left to revalidate (cleared mid-flight, or a server answering 304 unprompted): fetch outright.
            var unconditional = raw
            unconditional.headers = unconditional.headers.filter { $0.key.lowercased() != "if-none-match" }
            fetched = try await send(unconditional)
            guard fetched.response.status != 304 else { throw IonError.http(status: 304, errors: []) }
        }
        let typed = try await Store.decodePrimaries(of: fetched.document, as: T.self, codec: codec)
        return ingest(fetched, typed: typed, request: request, key: key, startSequence: startSequence)
    }

    /// Whether a caller may adopt an in-flight GET instead of starting its own.
    private func canJoin(_ flight: InFlight, key: RequestKey) -> Bool {
        guard flight.startSequence == mutationCounter else { return false }
        guard let invalidatedAt = requests[key]?.invalidatedAt else { return true }
        return flight.startedAt > invalidatedAt
    }

    /// Writes a response into both caches and tells the alive collection for the key, if any. The request cache
    /// keeps a newer document over a slower response that was sent earlier.
    @discardableResult
    func ingest<T: Resource>(_ fetched: Fetched, typed: [ResourceKey: T], request: Request<JSONAPIDocument>, key: RequestKey, startSequence: Int) -> CachedDocument {
        let document = fetched.document
        for object in document.allObjects {
            guard let objectKey = object.key else { continue }
            resources.upsert(object, typed: typed[objectKey], codec: codec, startSequence: startSequence)
        }
        var isCollection = false
        if case .many = document.data { isCollection = true }
        let cached = CachedDocument(
            primary: document.data?.objects.compactMap(\.key) ?? [],
            included: document.included.compactMap(\.key),
            isCollection: isCollection,
            links: document.links ?? Links(),
            meta: document.meta,
            op: request.op,
            receivedAt: fetched.receivedAt,
            types: request.cache.types,
            serverExpiry: CacheHeaders.expiry(of: fetched.response, receivedAt: fetched.receivedAt),
            etag: fetched.response.header("ETag")
        )
        let cacheable = request.method == .get || request.cache.key != nil
        if cacheable, !CacheHeaders.directives(in: fetched.response).noStore, document.errors == nil {
            if let existing = requests[key], existing.receivedAt > fetched.sentAt {
                return cached   // a response to a later request already landed
            }
            requests[key] = cached
            collections[key]?.value?.apply(cached)
        }
        return cached
    }

    // MARK: Outcomes

    /// `perform` with the outcome reported to `onError` and `lastTransportError`; for requests no other caller shares.
    func send(_ raw: RawRequest, accepting: Set<Int> = []) async throws -> Fetched {
        let sentAt = Date()
        do {
            let fetched = try await Store.perform(raw, chain: chain, sentAt: sentAt, accepting: accepting)
            record(nil, for: raw, sentAt: sentAt)
            return fetched
        } catch {
            let error = IonError(error)
            record(error, for: raw, sentAt: sentAt)
            throw error
        }
    }

    /// Updates `lastTransportError` (the latest-sent request wins) and calls `onError` for transport and HTTP
    /// errors. A cancelled request reports nothing; a response that did not decode still proves the server answered.
    func record(_ error: IonError?, for raw: RawRequest, sentAt: Date) {
        if case .cancelled? = error { return }
        if sentAt >= lastOutcomeSentAt {
            lastOutcomeSentAt = sentAt
            if case .transport? = error {
                lastTransportError = error
            } else if lastTransportError != nil {
                lastTransportError = nil
            }
        }
        guard let error else { return }
        switch error {
        case .transport, .http:
            onError?(error, raw)
        default:
            break
        }
    }

    /// Runs the handler chain and maps a status outside 2xx and `accepting` to `IonError.http`. Nonisolated.
    nonisolated static func exchange(_ raw: RawRequest, chain: HandlerChain, accepting: Set<Int> = []) async throws -> RawResponse {
        let response: RawResponse
        do {
            response = try await chain.perform(raw)
        } catch {
            throw IonError(error)
        }
        guard response.isSuccess || accepting.contains(response.status) else {
            let errors = (try? JSONAPIDocument.decode(response.data))?.errors ?? []
            throw IonError.http(status: response.status, errors: errors)
        }
        return response
    }

    /// Runs the handler chain and decodes the wire document. Nonisolated, so it leaves the main actor.
    /// A 304 to a GET, and any status in `accepting`, comes back as an empty document with the response attached;
    /// every other non-2xx throws.
    nonisolated static func perform(_ raw: RawRequest, chain: HandlerChain, sentAt: Date = Date(), accepting: Set<Int> = []) async throws -> Fetched {
        let accepted = raw.method == .get ? accepting.union([304]) : accepting
        let response = try await exchange(raw, chain: chain, accepting: accepted)
        let receivedAt = Date()
        if !response.isSuccess {
            return Fetched(document: JSONAPIDocument(), response: response, receivedAt: receivedAt, sentAt: sentAt)
        }
        do {
            return Fetched(document: try JSONAPIDocument.decode(response.data), response: response, receivedAt: receivedAt, sentAt: sentAt)
        } catch {
            throw IonError.decoding(nil, error)
        }
    }

    /// Decodes the primary objects as `T`, failing the request when one does not decode.
    ///
    /// Plain `throws` on purpose (see `ResourceCache.live`); the caller converts to `IonError`.
    nonisolated static func decodePrimaries<T: Resource>(of document: JSONAPIDocument, as type: T.Type, codec: ResourceCodec) async throws -> [ResourceKey: T] {
        guard T.self != NoResource.self else { return [:] }
        var typed: [ResourceKey: T] = [:]
        for object in document.data?.objects ?? [] {
            guard let key = object.key else { continue }
            typed[key] = try codec.decode(object)
        }
        return typed
    }

    // MARK: Live instances

    /// The live instance for a key, decoding a raw entry on first access. Nil when the key is not cached or does
    /// not decode as `T`.
    public func peek<T: Resource>(_ type: T.Type, key: ResourceKey) -> Live<T>? {
        try? resources.live(for: key, as: T.self, codec: codec)
    }

    /// The live instance for a key; throws `notFound` when it is not cached and `decoding` when it does not decode.
    /// Plain `throws` on purpose (see `ResourceCache.live`); always an `IonError`.
    func liveResource<T: Resource>(for key: ResourceKey, as type: T.Type) throws -> Live<T> {
        guard let live = try resources.live(for: key, as: T.self, codec: codec) else {
            throw IonError.notFound(key)
        }
        return live
    }

    /// `find` with plain `throws`, for generic callers inside the package (see `ResourceCache.live`).
    func findLive<T: Resource>(_ type: T.Type, id: String, include: [String] = [], cache: CacheOptions = .default) async throws -> Live<T> {
        try await findLive(T.self, request: .find(T.self, id: id, include: include, cache: cache))
    }

    /// `find(_:request:)` with plain `throws` (see `ResourceCache.live`).
    func findLive<T: Resource>(_ type: T.Type, request: Request<JSONAPIDocument>) async throws -> Live<T> {
        let document = try await load(request, as: T.self)
        guard !document.isCollection else {
            throw IonError.decoding(nil, CodecError.unexpectedCollection(path: request.path))
        }
        guard let key = document.primary.first else {
            throw IonError.notFound(request.records.first ?? ResourceKey(type: T.resourceType, id: request.path))
        }
        return try liveResource(for: key, as: T.self)
    }

    // MARK: Collections

    func aliveCollections(ofType type: String?) -> [any AnyLiveCollection] {
        collections = collections.filter { $0.value.value != nil }
        return collections.values.compactMap(\.value).filter { type == nil || $0.resourceType == type }
    }

    /// Materializes a cached document back into a wire document from the current raw entries.
    func document(from cached: CachedDocument) -> JSONAPIDocument {
        let primary = cached.primary.compactMap { resources.entry(for: $0)?.raw }
        let included = cached.included.compactMap { resources.entry(for: $0)?.raw }
        let data: PrimaryData = cached.isCollection ? .many(primary) : .one(primary.first)
        return JSONAPIDocument(data: data, included: included, links: cached.links.isEmpty ? nil : cached.links, meta: cached.meta)
    }
}

/// A decoded response with the raw response it came from.
struct Fetched: Sendable {
    var document: JSONAPIDocument
    var response: RawResponse
    var receivedAt: Date
    /// When the request left the store; a 304 validates the cached document as of this instant.
    var sentAt: Date
}

/// A GET on its way, shared by every caller of the same key.
struct InFlight {
    let task: Task<Fetched, any Error>
    let startedAt: Date
    /// The store's mutation counter when the request started.
    let startSequence: Int
}

extension RawRequest {
    /// Case-insensitive header presence.
    func hasHeader(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return headers.keys.contains { $0.lowercased() == lowered }
    }
}

/// A weak reference into the collection registry.
@MainActor
final class WeakCollection {
    weak var value: (any AnyLiveCollection)?

    init(_ value: any AnyLiveCollection) {
        self.value = value
    }
}
