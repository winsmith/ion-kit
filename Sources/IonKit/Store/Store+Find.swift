import Foundation

extension Store {
    /// Fetches one resource, serving it from the cache when the policy allows, and returns its live instance.
    ///
    /// Usage: `let person = try await store.find(Person.self, id: "42", include: ["tags"])`
    public func find<T: Resource>(_ type: T.Type, id: String, include: [String] = [], cache: CacheOptions = .default) async throws -> Live<T> {
        try await findLive(T.self, id: id, include: include, cache: cache)
    }

    /// The cached live instance for an id, without a request. Decodes a raw included entry on first access.
    public func peek<T: Resource>(_ type: T.Type, id: String) -> Live<T>? {
        peek(T.self, key: ResourceKey(T.self, id: id))
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
        let response: RawResponse
        do {
            response = try await chain.perform(raw)
        } catch {
            throw IonError(error)
        }
        guard response.isSuccess else {
            let errors = (try? JSONAPIDocument.decode(response.data))?.errors ?? []
            throw IonError.http(status: response.status, errors: errors)
        }
        do {
            return try codec.makeDecoder().decode(Response.self, from: response.data)
        } catch {
            throw IonError.decoding(nil, error)
        }
    }
}
