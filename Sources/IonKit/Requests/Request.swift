import Foundation

/// HTTP methods IonKit uses.
public enum HTTPMethod: String, Sendable, Hashable {
    case get = "GET"
    case post = "POST"
    case patch = "PATCH"
    case delete = "DELETE"
}

/// What a request means to the cache: which invalidation rules apply after it succeeds.
public enum Operation: Sendable, Hashable {
    case find, query, create, update, delete, custom
}

/// Per-request cache control.
///
/// Usage: `store.find(Person.self, id: id, cache: .reload)`
public struct CacheOptions: Sendable, Hashable {
    /// Explicit request-cache key; required to cache a POST query. Default: derived from method + URL.
    public var key: String?
    /// Skip the cache and wait for the network.
    public var reload: Bool
    /// Serve the cached document (when there is one) and refetch in the background.
    public var backgroundReload: Bool
    /// Resource types whose cached queries this request invalidates after success, and (for a query) which
    /// types' mutations invalidate it. Default for store builders: the resource type of the request.
    public var types: Set<String>?

    public init(key: String? = nil, reload: Bool = false, backgroundReload: Bool = false, types: Set<String>? = nil) {
        self.key = key
        self.reload = reload
        self.backgroundReload = backgroundReload
        self.types = types
    }

    public static let `default` = CacheOptions()
    public static let reload = CacheOptions(reload: true)
    public static let backgroundReload = CacheOptions(backgroundReload: true)
}

/// A request as app code and the store describe it, before it is resolved against the base URL.
///
/// Usage: `Request<JSONAPIDocument>(method: .get, path: "people/42")`
public struct Request<Response: Decodable & Sendable>: Sendable {
    public var method: HTTPMethod
    /// `"people/42"` relative to the store's base URL, or an absolute URL.
    public var path: String
    public var query: [URLQueryItem]
    public var headers: [String: String]
    public var body: Data?
    // swiftlint:disable:next identifier_name - public API; renaming `op` would break consumers
    public var op: Operation
    /// Primary resources of a mutation.
    public var records: [ResourceKey]
    public var cache: CacheOptions

    public init(
        method: HTTPMethod, path: String, query: [URLQueryItem] = [], headers: [String: String] = [:],
        // swiftlint:disable:next identifier_name - matches the `op` property
        body: Data? = nil, op: Operation = .custom, records: [ResourceKey] = [], cache: CacheOptions = .default
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
        self.op = op
        self.records = records
        self.cache = cache
    }

    /// The same request decoded as another response type.
    public func decoding<Other: Decodable & Sendable>(_ type: Other.Type) -> Request<Other> {
        Request<Other>(method: method, path: path, query: query, headers: headers, body: body, op: op, records: records, cache: cache)
    }
}

/// Two requests are equal when every member is, query items in the order given; `RequestKey` sorts the query, so
/// requests that differ only in query order are unequal here but share one cache entry.
///
/// Usage: `.task(id: request) { … }` in a view that refetches when its request changes.
extension Request: Hashable {}

extension Request where Response == JSONAPIDocument {
    /// A GET for a single resource.
    public static func find<T: Resource>(_ type: T.Type, id: String, include: [String] = [], cache: CacheOptions = .default) -> Request {
        var query: [URLQueryItem] = []
        if !include.isEmpty { query.append(URLQueryItem(name: "include", value: include.joined(separator: ","))) }
        var cache = cache
        if cache.types == nil { cache.types = [T.resourceType] }
        return Request(method: .get, path: "\(T.collectionPath)/\(id)", query: query, op: .find, records: [ResourceKey(T.self, id: id)], cache: cache)
    }

    /// A GET for a collection, with JSON:API `filter`, `sort`, `page` and `include` parameters.
    public static func query<T: Resource>(
        _ type: T.Type, path: String? = nil, filter: [String: String] = [:], sort: [String] = [],
        page: [String: String] = [:], include: [String] = [], query extra: [URLQueryItem] = [], cache: CacheOptions = .default
    ) -> Request {
        var query = extra
        for (name, value) in filter { query.append(URLQueryItem(name: "filter[\(name)]", value: value)) }
        if !sort.isEmpty { query.append(URLQueryItem(name: "sort", value: sort.joined(separator: ","))) }
        for (name, value) in page { query.append(URLQueryItem(name: "page[\(name)]", value: value)) }
        if !include.isEmpty { query.append(URLQueryItem(name: "include", value: include.joined(separator: ","))) }
        var cache = cache
        if cache.types == nil { cache.types = [T.resourceType] }
        return Request(method: .get, path: path ?? T.collectionPath, query: query, op: .query, cache: cache)
    }
}

/// Identifies a request in the request cache: method plus the resolved URL with sorted query, or an explicit key.
public struct RequestKey: Hashable, Sendable, CustomStringConvertible {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }

    public init(method: HTTPMethod, url: URL) {
        self.init("\(method.rawValue) \(url.absoluteString)")
    }

    public var description: String { value }
}

/// A request after the store resolved it against its base URL and added the JSON:API headers.
/// This is what handlers see.
public struct RawRequest: Sendable, Hashable {
    public var method: HTTPMethod
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: HTTPMethod, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }

    /// The request-cache key: method plus URL with its query sorted.
    public var key: RequestKey { RequestKey(method: method, url: url) }
}

/// What the terminal handler returns.
public struct RawResponse: Sendable, Hashable {
    public let status: Int
    public let headers: [String: String]
    public let data: Data

    public init(status: Int, headers: [String: String] = [:], data: Data = Data()) {
        self.status = status
        self.headers = headers
        self.data = data
    }

    /// Header lookup ignoring case.
    public func header(_ name: String) -> String? {
        if let value = headers[name] { return value }
        let lowered = name.lowercased()
        return headers.first { $0.key.lowercased() == lowered }?.value
    }

    /// True for 2xx.
    public var isSuccess: Bool { (200..<300).contains(status) }
}

extension RawRequest {
    /// Resolves a request against a base URL: relative paths are appended, absolute URLs are kept, the query is
    /// sorted so that `filter[a]&filter[b]` and `filter[b]&filter[a]` share a cache entry, and the JSON:API
    /// headers are added.
    public init<R>(_ request: Request<R>, baseURL: URL) throws(IonError) {
        guard var components = Self.components(for: request.path, baseURL: baseURL) else {
            throw .transport(URLError(.badURL, userInfo: [NSLocalizedDescriptionKey: "Invalid request path: \(request.path)"]))
        }
        var items = components.queryItems ?? []
        items.append(contentsOf: request.query)
        if !items.isEmpty {
            components.queryItems = items.sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
        }
        guard let url = components.url else {
            throw .transport(URLError(.badURL, userInfo: [NSLocalizedDescriptionKey: "Invalid request path: \(request.path)"]))
        }
        var headers = ["Accept": JSONAPIDocument.mediaType]
        if request.body != nil { headers["Content-Type"] = JSONAPIDocument.mediaType }
        for (name, value) in request.headers { headers[name] = value }
        self.init(method: request.method, url: url, headers: headers, body: request.body)
    }

    private static func components(for path: String, baseURL: URL) -> URLComponents? {
        if let absolute = URL(string: path), absolute.scheme != nil {
            return URLComponents(url: absolute, resolvingAgainstBaseURL: false)
        }
        var base = baseURL.absoluteString
        if !base.hasSuffix("/") { base += "/" }
        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let url = URL(string: base + relative) else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)
    }
}
