import Foundation
import Observation

/// What the store needs from a `LiveCollection<T>` without knowing `T`.
@MainActor
protocol AnyLiveCollection: AnyObject {
    var resourceType: String { get }
    var autoRefresh: Bool { get }
    func remove(_ key: ResourceKey)
    func apply(_ document: CachedDocument)
    func reloadInBackground()
}

/// An observable, ordered list of live instances for one query, plus its pagination links and meta.
/// Two screens showing the same query share one instance; it dies with its last view. It holds the store weakly:
/// a reload that outlives its store (logout, a test ending) fails with `IonError.cancelled` instead of crashing.
///
/// Usage: `ForEach(collection.items) { live in Row(person: live.value) }`
@MainActor @Observable
public final class LiveCollection<T: Resource>: AnyLiveCollection {
    /// The live instances in the server's order, with deleted resources already filtered out.
    public private(set) var items: [Live<T>] = []
    /// The last loaded page's links (`next` drives `loadMore()`).
    public private(set) var links = Links()
    /// The last loaded page's meta.
    public private(set) var meta: [String: JSONValue] = [:]
    public private(set) var state: LoadState = .idle
    /// Reload after a mutation of this resource type succeeds. Default: true.
    public var autoRefresh = true

    /// The request-cache key of the first page.
    public let key: RequestKey
    @ObservationIgnored let request: Request<JSONAPIDocument>
    @ObservationIgnored private(set) weak var store: Store?
    @ObservationIgnored private(set) var primaryKeys: [ResourceKey] = []

    nonisolated public var resourceType: String { T.resourceType }

    init(store: Store, key: RequestKey, request: Request<JSONAPIDocument>) {
        self.store = store
        self.key = key
        self.request = request
    }

    /// Refetches the first page from the network and drops pages appended by `loadMore()`.
    public func reload() async throws {
        try await load(reload: true)
    }

    /// Fetches `links.next` and appends its items. Does nothing without a next link.
    public func loadMore() async throws {
        guard let next = links.next else { return }
        guard let store else { throw IonError.cancelled }
        var pageRequest = request
        pageRequest.path = next.href
        pageRequest.query = []
        let document = try await store.load(pageRequest, as: T.self)
        append(document)
    }

    /// True when a next page is available.
    public var hasMore: Bool { links.next != nil }

    // MARK: Internal

    func load(reload: Bool) async throws {
        guard let store else { throw IonError.cancelled }
        var request = self.request
        if reload { request.cache.reload = true }
        if primaryKeys.isEmpty, !state.isLoaded { state = .loading }
        do {
            let document = try await store.load(request, as: T.self)
            apply(document)
        } catch {
            let error = IonError(error)
            if case .cancelled = error, items.isEmpty {
                state = .idle
            } else if items.isEmpty {
                state = .failed(error)
            }
            throw error
        }
    }

    func apply(_ document: CachedDocument) {
        primaryKeys = document.primary
        links = document.links
        meta = document.meta ?? [:]
        materialize()
        state = .loaded
    }

    private func append(_ document: CachedDocument) {
        let known = Set(primaryKeys)
        primaryKeys.append(contentsOf: document.primary.filter { !known.contains($0) })
        links = document.links
        meta = document.meta ?? [:]
        materialize()
    }

    private func materialize() {
        guard let store else {
            items = []
            return
        }
        items = primaryKeys.compactMap { key in
            guard let live = store.peek(T.self, key: key), !live.isDeleted else { return nil }
            return live
        }
    }

    func remove(_ key: ResourceKey) {
        guard primaryKeys.contains(key) else { return }
        primaryKeys.removeAll { $0 == key }
        materialize()
    }

    func reloadInBackground() {
        Task { try? await reload() }
    }
}
