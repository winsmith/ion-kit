#if canImport(SwiftUI)
import SwiftUI

/// Loads one resource or a collection through the store in the environment (or the one passed in) and shows a
/// loading view, the content, or a failure view with a retry. The content keeps updating through Observation like
/// any `Live` / `LiveCollection`; a cached result shows at once, a changed request or store loads again.
///
/// Usage:
/// ```swift
/// Fetch(Person.self, id: id, include: ["tags"]) { person in PersonDetail(person: person) }
/// Fetch(Person.self, sort: ["name"]) { people in
///     List(people.items) { Row(person: $0.value) }
/// } loading: {
///     ProgressView()
/// } failed: { error, retry in
///     ContentUnavailableView { Text(error.localizedDescription) } actions: { Button("Try Again") { retry() } }
/// }
/// ```
public struct Fetch<Value, Content: View, Loading: View, Failed: View>: View {
    private let request: Request<JSONAPIDocument>
    private let explicitStore: Store?
    private let load: @MainActor (Store, Request<JSONAPIDocument>) async throws(IonError) -> Value
    private let peek: @MainActor (Store, Request<JSONAPIDocument>) -> Value?
    private let content: (Value) -> Content
    private let loading: () -> Loading
    private let failed: (IonError, @escaping @MainActor () -> Void) -> Failed

    @Environment(Store.self) private var environmentStore: Store?
    @State private var phase: Phase = .loading
    @State private var attempt = 0
    /// The load for `current`. Cancelled when the request, store or attempt changes, not on disappear.
    @State private var loadTask: Task<Void, Never>?
    /// The run whose result may still be shown; a finished load for any other run is dropped.
    @State private var current: Run?

    private enum Phase {
        case loading
        case loaded(Value)
        case failed(IonError)
    }

    /// Identity of one load: a change restarts the task.
    private struct Run: Hashable {
        var request: Request<JSONAPIDocument>
        var store: ObjectIdentifier
        var attempt: Int
    }

    // MARK: Single resource

    /// Fetches one resource by id, like `store.find(T.self, id:include:cache:)`.
    public init<T: Resource>(
        _ type: T.Type, id: String, include: [String] = [], cache: CacheOptions = .default, store: Store? = nil,
        @ViewBuilder content: @escaping (Live<T>) -> Content,
        @ViewBuilder loading: @escaping () -> Loading,
        @ViewBuilder failed: @escaping (IonError, _ retry: @escaping @MainActor () -> Void) -> Failed
    ) where Value == Live<T> {
        self.init(
            request: .find(T.self, id: id, include: include, cache: cache), store: store,
            load: { store, request throws(IonError) in try await store.find(T.self, request: request) },
            peek: { store, request in store.cachedLive(T.self, request: request) },
            content: content, loading: loading, failed: failed
        )
    }

    // MARK: Collections

    /// Fetches a collection with JSON:API `filter`, `sort`, `page` and `include`, like `store.query`.
    public init<T: Resource>(
        _ type: T.Type, filter: [String: String] = [:], sort: [String] = [], page: [String: String] = [:],
        include: [String] = [], cache: CacheOptions = .default, store: Store? = nil,
        @ViewBuilder content: @escaping (LiveCollection<T>) -> Content,
        @ViewBuilder loading: @escaping () -> Loading,
        @ViewBuilder failed: @escaping (IonError, _ retry: @escaping @MainActor () -> Void) -> Failed
    ) where Value == LiveCollection<T> {
        self.init(
            T.self, request: .query(T.self, filter: filter, sort: sort, page: page, include: include, cache: cache),
            store: store, content: content, loading: loading, failed: failed
        )
    }

    /// Fetches a collection for any GET request built by app code, like `store.query(T.self, request:)`.
    public init<T: Resource>(
        _ type: T.Type, request: Request<JSONAPIDocument>, store: Store? = nil,
        @ViewBuilder content: @escaping (LiveCollection<T>) -> Content,
        @ViewBuilder loading: @escaping () -> Loading,
        @ViewBuilder failed: @escaping (IonError, _ retry: @escaping @MainActor () -> Void) -> Failed
    ) where Value == LiveCollection<T> {
        self.init(
            request: request, store: store,
            load: { store, request throws(IonError) in try await store.query(T.self, request: request) },
            peek: { store, request in store.cachedCollection(T.self, request: request) },
            content: content, loading: loading, failed: failed
        )
    }

    private init(
        request: Request<JSONAPIDocument>, store: Store?,
        load: @escaping @MainActor (Store, Request<JSONAPIDocument>) async throws(IonError) -> Value,
        peek: @escaping @MainActor (Store, Request<JSONAPIDocument>) -> Value?,
        content: @escaping (Value) -> Content,
        loading: @escaping () -> Loading,
        failed: @escaping (IonError, @escaping @MainActor () -> Void) -> Failed
    ) {
        self.request = request
        self.explicitStore = store
        self.load = load
        self.peek = peek
        self.content = content
        self.loading = loading
        self.failed = failed
    }

    // MARK: View

    public var body: some View {
        Group {
            switch phase {
            case .loading:
                loading()
            case .loaded(let value):
                content(value)
            case .failed(let error):
                failed(error, retry)
            }
        }
        .onChange(of: run, initial: true) { _, run in
            // Show what the cache has before the load runs, so switching between cached items never flashes.
            if let value = peek(resolvedStore, request) {
                phase = .loaded(value)
            } else {
                phase = .loading
            }
            start(run)
        }
    }

    /// Starts the load for `run` in a task of its own rather than `.task(id:)`: SwiftUI can send a view
    /// `onDisappear` right after `onAppear` and keep showing it (a collapsed `NavigationSplitView` pushing its
    /// detail column does), which cancels a `.task` that is then never started again and leaves the view loading.
    /// The request keeps running for other callers either way, so finishing it after a real disappear costs nothing.
    private func start(_ run: Run) {
        loadTask?.cancel()
        current = run
        var request = request
        if attempt > 0 { request.cache.reload = true }
        let store = resolvedStore
        loadTask = Task {
            let next: Phase
            do throws(IonError) {   // a closure body does not infer the thrown type of a `do`
                next = .loaded(try await load(store, request))
            } catch .cancelled {
                return
            } catch {
                next = .failed(error)
            }
            if !Task.isCancelled, current == run { phase = next }
        }
    }

    private var run: Run {
        Run(request: request, store: ObjectIdentifier(resolvedStore), attempt: attempt)
    }

    private var resolvedStore: Store {
        if let store = explicitStore ?? environmentStore { return store }
        preconditionFailure("Fetch needs a Store: put one in the environment with .environment(store) or pass store:")
    }

    /// Loads again, bypassing the cache.
    private func retry() {
        attempt += 1
    }
}

extension Fetch where Loading == ProgressView<EmptyView, EmptyView>, Failed == FetchFailureView {
    /// `Fetch(Person.self, id:)` with a `ProgressView` while loading and `FetchFailureView` on failure.
    public init<T: Resource>(
        _ type: T.Type, id: String, include: [String] = [], cache: CacheOptions = .default, store: Store? = nil,
        @ViewBuilder content: @escaping (Live<T>) -> Content
    ) where Value == Live<T> {
        self.init(T.self, id: id, include: include, cache: cache, store: store, content: content,
                  loading: { ProgressView() }, failed: { FetchFailureView(error: $0, retry: $1) })
    }

    /// `Fetch(Person.self, filter:sort:…)` with a `ProgressView` while loading and `FetchFailureView` on failure.
    public init<T: Resource>(
        _ type: T.Type, filter: [String: String] = [:], sort: [String] = [], page: [String: String] = [:],
        include: [String] = [], cache: CacheOptions = .default, store: Store? = nil,
        @ViewBuilder content: @escaping (LiveCollection<T>) -> Content
    ) where Value == LiveCollection<T> {
        self.init(T.self, filter: filter, sort: sort, page: page, include: include, cache: cache, store: store,
                  content: content, loading: { ProgressView() }, failed: { FetchFailureView(error: $0, retry: $1) })
    }

    /// `Fetch(Person.self, request:)` with a `ProgressView` while loading and `FetchFailureView` on failure.
    public init<T: Resource>(
        _ type: T.Type, request: Request<JSONAPIDocument>, store: Store? = nil,
        @ViewBuilder content: @escaping (LiveCollection<T>) -> Content
    ) where Value == LiveCollection<T> {
        self.init(T.self, request: request, store: store, content: content,
                  loading: { ProgressView() }, failed: { FetchFailureView(error: $0, retry: $1) })
    }
}

extension Fetch where Loading == ProgressView<EmptyView, EmptyView> {
    /// `Fetch(Person.self, id:)` with a `ProgressView` while loading and a custom failure view.
    public init<T: Resource>(
        _ type: T.Type, id: String, include: [String] = [], cache: CacheOptions = .default, store: Store? = nil,
        @ViewBuilder content: @escaping (Live<T>) -> Content,
        @ViewBuilder failed: @escaping (IonError, _ retry: @escaping @MainActor () -> Void) -> Failed
    ) where Value == Live<T> {
        self.init(T.self, id: id, include: include, cache: cache, store: store, content: content,
                  loading: { ProgressView() }, failed: failed)
    }

    /// `Fetch(Person.self, filter:sort:…)` with a `ProgressView` while loading and a custom failure view.
    public init<T: Resource>(
        _ type: T.Type, filter: [String: String] = [:], sort: [String] = [], page: [String: String] = [:],
        include: [String] = [], cache: CacheOptions = .default, store: Store? = nil,
        @ViewBuilder content: @escaping (LiveCollection<T>) -> Content,
        @ViewBuilder failed: @escaping (IonError, _ retry: @escaping @MainActor () -> Void) -> Failed
    ) where Value == LiveCollection<T> {
        self.init(T.self, filter: filter, sort: sort, page: page, include: include, cache: cache, store: store,
                  content: content, loading: { ProgressView() }, failed: failed)
    }
}

/// What `Fetch` shows on failure unless told otherwise: a `ContentUnavailableView` with the error's
/// `localizedDescription` and a "Try Again" button that reloads past the cache.
///
/// Usage: `failed: { error, retry in FetchFailureView(error: error, retry: retry) }`
public struct FetchFailureView: View {
    public let error: IonError
    public let retry: @MainActor () -> Void

    public init(error: IonError, retry: @escaping @MainActor () -> Void) {
        self.error = error
        self.retry = retry
    }

    public var body: some View {
        ContentUnavailableView {
            Label("Couldn't Load", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error.localizedDescription)
        } actions: {
            Button("Try Again") { retry() }
        }
    }
}
#endif
