import Foundation
import Observation

/// One store per API and session: owns the handler chain, both caches and every live instance.
///
/// Views call the store; the store runs requests through the handler chain off the main actor; responses are
/// upserted into the resource cache; the cache updates the `Live` instances views observe.
///
/// Usage: `let store = Store(baseURL: url, handlers: [BearerTokenHandler { token }, URLSessionHandler()])`
@MainActor @Observable
public final class Store {
    public let baseURL: URL
    @ObservationIgnored public let codec: ResourceCodec
    /// Decides fresh / stale / expired for cached documents; overridable per store.
    @ObservationIgnored public var cachePolicy: any CachePolicy

    @ObservationIgnored let chain: HandlerChain
    @ObservationIgnored let resources = ResourceCache()
    @ObservationIgnored let requests = RequestCache()
    @ObservationIgnored var inflight: [RequestKey: Task<Fetched, any Error>] = [:]
    @ObservationIgnored var collections: [RequestKey: WeakCollection] = [:]
    /// Incremented on every successful local mutation; entries remember the value at their last mutation.
    @ObservationIgnored var mutationCounter = 0

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
    /// Call after a push notification, say.
    public func invalidate(type: String) {
        requests.invalidate(type: type)
        for collection in aliveCollections(ofType: type) where collection.autoRefresh {
            collection.reloadInBackground()
        }
    }

    /// Marks every cached document whose primary data lists the key expired.
    public func invalidate(key: ResourceKey) {
        requests.invalidate(key: key)
    }

    /// Drops every cached resource and document, for logout. Alive collections become empty until reloaded.
    public func clear() {
        resources.removeAll()
        requests.removeAll()
        for collection in aliveCollections(ofType: nil) {
            collection.apply(CachedDocument(primary: [], isCollection: true, op: .query))
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

    /// A GET's cache step followed, when needed, by a fetch. Returns the keys of the result.
    func load<T: Resource>(_ request: Request<JSONAPIDocument>, as type: T.Type) async throws(IonError) -> CachedDocument {
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
    func load(_ request: Request<JSONAPIDocument>) async throws(IonError) -> CachedDocument {
        try await load(request, as: NoResource.self)
    }

    private func refetchInBackground<T: Resource>(_ request: Request<JSONAPIDocument>, raw: RawRequest, key: RequestKey, as type: T.Type) {
        guard inflight[key] == nil else { return }
        Task { try? await fetch(request, raw: raw, key: key, as: T.self) }
    }

    /// Runs the request (deduplicated with other in-flight GETs of the same key), decodes the primary objects as
    /// `T` off the main actor, then upserts everything and records the document.
    func fetch<T: Resource>(_ request: Request<JSONAPIDocument>, raw: RawRequest, key: RequestKey, as type: T.Type) async throws(IonError) -> CachedDocument {
        let startSequence = mutationCounter
        let fetched: Fetched
        if request.method == .get {
            let task: Task<Fetched, any Error>
            var owned = false
            if let existing = inflight[key] {
                task = existing
            } else {
                let chain = self.chain
                task = Task.detached { try await Store.perform(raw, chain: chain) }
                inflight[key] = task
                owned = true
            }
            defer { if owned { inflight[key] = nil } }
            do {
                fetched = try await task.value
            } catch {
                throw IonError(error)
            }
            if Task.isCancelled { throw .cancelled }
        } else {
            fetched = try await Store.perform(raw, chain: chain)
        }
        let typed = try await Store.decodePrimaries(of: fetched.document, as: T.self, codec: codec)
        return ingest(fetched, typed: typed, request: request, key: key, startSequence: startSequence)
    }

    /// Writes a response into both caches and tells the alive collection for the key, if any.
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
            serverExpiry: CacheHeaders.expiry(of: fetched.response, receivedAt: fetched.receivedAt)
        )
        let cacheable = request.method == .get || request.cache.key != nil
        if cacheable, !CacheHeaders.directives(in: fetched.response).noStore, document.errors == nil {
            requests[key] = cached
            collections[key]?.value?.apply(cached)
        }
        return cached
    }

    /// Runs the handler chain and decodes the wire document. Nonisolated, so it leaves the main actor.
    nonisolated static func perform(_ raw: RawRequest, chain: HandlerChain) async throws(IonError) -> Fetched {
        let response: RawResponse
        do {
            response = try await chain.perform(raw)
        } catch {
            throw IonError(error)
        }
        let receivedAt = Date()
        guard response.isSuccess else {
            let errors = (try? JSONAPIDocument.decode(response.data))?.errors ?? []
            throw IonError.http(status: response.status, errors: errors)
        }
        do {
            return Fetched(document: try JSONAPIDocument.decode(response.data), response: response, receivedAt: receivedAt)
        } catch {
            throw IonError.decoding(nil, error)
        }
    }

    /// Decodes the primary objects as `T` off the main actor, failing the request when one does not decode.
    nonisolated static func decodePrimaries<T: Resource>(of document: JSONAPIDocument, as type: T.Type, codec: ResourceCodec) async throws(IonError) -> [ResourceKey: T] {
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
    func liveResource<T: Resource>(for key: ResourceKey, as type: T.Type) throws(IonError) -> Live<T> {
        guard let live = try resources.live(for: key, as: T.self, codec: codec) else {
            throw .notFound(key)
        }
        return live
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
}

/// A weak reference into the collection registry.
@MainActor
final class WeakCollection {
    weak var value: (any AnyLiveCollection)?

    init(_ value: any AnyLiveCollection) {
        self.value = value
    }
}
