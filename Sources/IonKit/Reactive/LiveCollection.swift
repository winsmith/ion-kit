import Foundation
import Observation

/// What the store needs from a `LiveCollection<T>` without knowing `T`.
@MainActor
protocol AnyLiveCollection: AnyObject {
    var resourceType: String { get }
    var autoRefresh: Bool { get }
    func remove(_ key: ResourceKey)
    func apply(_ document: CachedDocument)
    func reset()
    func reloadInBackground()
}

/// An observable, ordered list of live instances for one query, plus its pagination links and meta.
/// Two screens showing the same query share one instance; it dies with its last view. It holds the store weakly:
/// a reload that outlives its store (logout, a test ending) fails with `IonError.cancelled` instead of crashing.
///
/// Pages appended by `loadMore()` stay until `reload()`, which refetches every loaded page and swaps the result in
/// once. A background reload after a mutation of the type refetches the first page only and keeps the rest.
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
    /// True while a reload is running; `state` stays `.loaded` and `items` keep showing the previous result.
    public private(set) var isReloading = false
    /// Reload after a mutation of this resource type succeeds. Default: true.
    public var autoRefresh = true

    /// The request-cache key of the first page.
    public let key: RequestKey
    @ObservationIgnored let request: Request<JSONAPIDocument>
    @ObservationIgnored private(set) weak var store: Store?
    /// The primary keys of every loaded page, first page first.
    @ObservationIgnored private(set) var pages: [[ResourceKey]] = []
    @ObservationIgnored private var reloadTask: Task<Void, any Error>?
    @ObservationIgnored private var reloadingAllPages = false
    @ObservationIgnored private var reloadAgain = false
    @ObservationIgnored private var reloadAgainAllPages = false
    /// Bumped by `reset()`; a load that started under an older generation discards its result.
    @ObservationIgnored private var generation = 0

    nonisolated public var resourceType: String { T.resourceType }

    init(store: Store, key: RequestKey, request: Request<JSONAPIDocument>) {
        self.store = store
        self.key = key
        self.request = request
    }

    /// Refetches every loaded page from the network and replaces `items` once all of them arrived; until then the
    /// previous result stays on screen. Concurrent reloads are coalesced into one. A failed page leaves the
    /// collection as it was and throws.
    public func reload() async throws {
        try await reload(allPages: true)
    }

    /// Fetches `links.next` and appends its items. Does nothing without a next link; waits for a running reload.
    public func loadMore() async throws {
        if let running = reloadTask {
            _ = try? await running.value
        }
        guard let next = links.next else { return }
        guard let store else { throw IonError.cancelled }
        let generation = self.generation
        var pageRequest = request
        pageRequest.path = next.href
        pageRequest.query = []
        let document = try await store.load(pageRequest, as: T.self)
        try checkAlive(generation)
        append(document)
    }

    /// True when a next page is available.
    public var hasMore: Bool { links.next != nil }

    // MARK: Internal

    /// Loads the first page, from the cache when the policy allows; `reload` refetches every loaded page.
    func load(reload: Bool) async throws {
        if reload {
            try await self.reload(allPages: true)
            return
        }
        guard let store else { throw IonError.cancelled }
        if pages.isEmpty, !state.isLoaded { state = .loading }
        let generation = self.generation
        do {
            let document = try await store.load(request, as: T.self)
            try checkAlive(generation)
            apply(document)
        } catch {
            try fail(with: error, generation: generation)
        }
    }

    private func reload(allPages: Bool) async throws {
        if let running = reloadTask {
            reloadAgain = true
            reloadAgainAllPages = reloadAgainAllPages || allPages
            try await running.value
            return
        }
        guard store != nil else { throw IonError.cancelled }
        if pages.isEmpty, !state.isLoaded { state = .loading }
        let generation = self.generation
        isReloading = true
        let task = Task { @MainActor [self] in
            // Cleared by the task itself, so a reload that arrives after the loop ended starts a new one instead of
            // joining a finished task. `reset()` bumps the generation and does its own cleanup.
            defer {
                if self.generation == generation {
                    reloadTask = nil
                    isReloading = false
                    reloadingAllPages = false
                }
            }
            var all = allPages
            repeat {
                reloadAgain = false
                reloadAgainAllPages = false
                reloadingAllPages = all
                try await runReload(allPages: all)
                all = reloadAgainAllPages
            } while reloadAgain
        }
        reloadTask = task
        do {
            try await task.value
        } catch {
            try fail(with: error, generation: generation)
        }
    }

    /// One pass: the first page with `reload`, then as many `next` pages as were loaded before (when `allPages`).
    private func runReload(allPages: Bool) async throws {
        guard let store else { throw IonError.cancelled }
        let generation = self.generation
        let count = allPages ? max(pages.count, 1) : 1
        var first = request
        first.cache.reload = true
        let firstPage = try await store.load(first, as: T.self)
        try checkAlive(generation)
        var loaded = [firstPage]
        while loaded.count < count, let next = loaded[loaded.count - 1].links.next {
            var pageRequest = request
            pageRequest.path = next.href
            pageRequest.query = []
            pageRequest.cache.reload = true
            let page = try await store.load(pageRequest, as: T.self)
            try checkAlive(generation)
            loaded.append(page)
        }
        guard allPages else {
            replaceFirstPage(loaded[0])
            return
        }
        pages = loaded.map(\.primary)
        let last = loaded[loaded.count - 1]
        links = last.links
        meta = last.meta ?? [:]
        materialize()
        state = .loaded
    }

    /// Called by the store whenever the first page's document is re-ingested (a load, a background revalidation
    /// from any screen). Replaces the first page and keeps appended pages; ignored while a full reload is running,
    /// which swaps everything in at the end.
    func apply(_ document: CachedDocument) {
        guard !reloadingAllPages else { return }
        replaceFirstPage(document)
    }

    private func replaceFirstPage(_ document: CachedDocument) {
        if pages.isEmpty {
            pages = [document.primary]
        } else {
            pages[0] = document.primary
        }
        if pages.count == 1 {
            links = document.links
            meta = document.meta ?? [:]
        }
        materialize()
        state = .loaded
    }

    private func append(_ document: CachedDocument) {
        pages.append(document.primary)
        links = document.links
        meta = document.meta ?? [:]
        materialize()
    }

    private func materialize() {
        guard let store else {
            items = []
            return
        }
        var seen = Set<ResourceKey>()
        items = pages.joined().compactMap { key in
            guard seen.insert(key).inserted, let live = store.peek(T.self, key: key), !live.isDeleted else { return nil }
            return live
        }
    }

    func remove(_ key: ResourceKey) {
        guard pages.contains(where: { $0.contains(key) }) else { return }
        pages = pages.map { page in page.filter { $0 != key } }
        materialize()
    }

    /// Empties the collection (`store.clear()`); a running reload is cancelled and its pages are discarded.
    func reset() {
        generation += 1
        reloadTask?.cancel()
        reloadTask = nil
        isReloading = false
        reloadingAllPages = false
        reloadAgain = false
        reloadAgainAllPages = false
        pages = []
        links = Links()
        meta = [:]
        items = []
        state = .idle
    }

    func reloadInBackground() {
        Task { try? await reload(allPages: false) }
    }

    private func checkAlive(_ generation: Int) throws {
        guard generation == self.generation, store != nil else { throw IonError.cancelled }
    }

    /// Records a failed load in `state` when nothing is on screen, then rethrows as `IonError`.
    private func fail(with error: any Error, generation: Int) throws {
        let error = IonError(error)
        if generation == self.generation, items.isEmpty {
            if case .cancelled = error {
                state = .idle
            } else {
                state = .failed(error)
            }
        }
        throw error
    }
}
