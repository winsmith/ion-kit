import Foundation

extension Store {
    /// Fetches one resource, serving it from the cache when the policy allows, and returns its live instance.
    ///
    /// Usage: `let person = try await store.find(Person.self, id: "42", include: ["tags"])`
    public func find<T: Resource>(_ type: T.Type, id: String, include: [String] = [], cache: CacheOptions = .default) async throws -> Live<T> {
        try await findLive(T.self, id: id, include: include, cache: cache)
    }

    /// Fetches one resource for any GET request built by app code (a singleton endpoint such as `GET me`, say).
    /// The response must carry a single resource object: `"data": null` throws `IonError.notFound` for the first
    /// of `request.records` (or a key made from the request path), a collection throws `IonError.decoding`.
    ///
    /// Usage: `let me = try await store.find(User.self, request: Request(method: .get, path: "me", op: .find))`
    public func find<T: Resource>(_ type: T.Type, request: Request<JSONAPIDocument>) async throws -> Live<T> {
        try await findLive(T.self, request: request)
    }

    /// The cached live instance for an id, without a request. Decodes a raw included entry on first access.
    public func peek<T: Resource>(_ type: T.Type, id: String) -> Live<T>? {
        peek(T.self, key: ResourceKey(T.self, id: id))
    }

    /// The cached result of a single-resource request when the policy would serve it without waiting. No request.
    func cachedLive<T: Resource>(_ type: T.Type, request: Request<JSONAPIDocument>) -> Live<T>? {
        guard request.method == .get, !request.cache.reload, let entry = cachedDocument(for: request) else { return nil }
        guard !entry.isCollection, let key = entry.primary.first else { return nil }
        return peek(T.self, key: key)
    }

    /// The alive collection for a request when it has loaded at least once. No request.
    func cachedCollection<T: Resource>(_ type: T.Type, request: Request<JSONAPIDocument>) -> LiveCollection<T>? {
        guard request.method == .get || request.cache.key != nil, !request.cache.reload else { return nil }
        guard let raw = try? RawRequest(request, baseURL: baseURL) else { return nil }
        let key = request.cache.key.map(RequestKey.init) ?? raw.key
        guard let collection = collections[key]?.value as? LiveCollection<T>, collection.state.isLoaded else { return nil }
        return collection
    }

    /// The cached document for a request unless the policy says it has expired.
    func cachedDocument(for request: Request<JSONAPIDocument>) -> CachedDocument? {
        guard let raw = try? RawRequest(request, baseURL: baseURL) else { return nil }
        let key = request.cache.key.map(RequestKey.init) ?? raw.key
        guard let entry = requests[key], cachePolicy.state(of: entry, now: Date()) != .expired else { return nil }
        return entry
    }

    /// Runs any request through the pipeline: a GET goes through the cache step, every response is upserted.
    ///
    /// Usage: `let doc = try await store.request(Request(method: .get, path: "people/42/relationships/tags"))`
    public func request(_ request: Request<JSONAPIDocument>) async throws -> JSONAPIDocument {
        let cached = try await load(request)
        if let types = request.cache.types, request.method != .get {
            for type in types { invalidate(type: type) }
        }
        return document(from: cached)
    }

    /// Runs a request whose response is not a JSON:API document. Nothing is cached or upserted.
    public func request<Response: Decodable & Sendable>(_ request: Request<Response>) async throws -> Response {
        let raw = try RawRequest(request, baseURL: baseURL)
        let sentAt = Date()
        let response: RawResponse
        do {
            response = try await Store.exchange(raw, chain: chain)
            record(nil, for: raw, sentAt: sentAt)
        } catch {
            let error = IonError(error)
            record(error, for: raw, sentAt: sentAt)
            throw error
        }
        do {
            return try codec.makeDecoder().decode(Response.self, from: response.data)
        } catch {
            throw IonError.decoding(nil, error)
        }
    }
}
