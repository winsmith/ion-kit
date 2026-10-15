import Foundation

extension Store {
    /// Fetches a collection with JSON:API `filter`, `sort`, `page` and `include` parameters and returns the one
    /// live collection for that query. Returns once the first page is loaded (at once when cached).
    ///
    /// Usage: `let people = try await store.query(Person.self, filter: ["name": "Ann"], sort: ["-updatedAt"])`
    public func query<T: Resource>(
        _ type: T.Type, filter: [String: String] = [:], sort: [String] = [], page: [String: String] = [:],
        include: [String] = [], cache: CacheOptions = .default
    ) async throws -> LiveCollection<T> {
        let request = Request<JSONAPIDocument>.query(T.self, filter: filter, sort: sort, page: page, include: include, cache: cache)
        return try await queryCollection(T.self, request: request)
    }

    /// Fetches a collection from a custom path such as `groups/3/members`.
    public func query<T: Resource>(
        _ type: T.Type, path: String, query items: [URLQueryItem] = [], include: [String] = [], cache: CacheOptions = .default
    ) async throws -> LiveCollection<T> {
        let request = Request<JSONAPIDocument>.query(T.self, path: path, include: include, query: items, cache: cache)
        return try await queryCollection(T.self, request: request)
    }

    /// Fetches a collection for any GET request built by app code.
    public func query<T: Resource>(_ type: T.Type, request: Request<JSONAPIDocument>) async throws -> LiveCollection<T> {
        return try await queryCollection(T.self, request: request)
    }

    /// Plain `throws` on purpose (see `ResourceCache.live`); always an `IonError`.
    func queryCollection<T: Resource>(_ type: T.Type, request: Request<JSONAPIDocument>) async throws -> LiveCollection<T> {
        let raw = try RawRequest(request, baseURL: baseURL)
        let key = request.cache.key.map(RequestKey.init) ?? raw.key
        let collection: LiveCollection<T>
        if let existing = collections[key]?.value as? LiveCollection<T> {
            collection = existing
        } else {
            var registered = request
            registered.cache.reload = false
            collection = LiveCollection<T>(store: self, key: key, request: registered)
            collections[key] = WeakCollection(collection)
        }
        try await collection.load(reload: request.cache.reload)
        return collection
    }
}
