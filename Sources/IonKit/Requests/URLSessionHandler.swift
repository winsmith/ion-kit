import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The terminal handler: performs the request with `URLSession` and returns the raw response.
///
/// Requests bypass the session's `URLCache`: the store's request cache is the only HTTP cache, so an invalidation
/// after a save is never answered from a cached pre-save response, and its own `If-None-Match` revalidation sees
/// real 304s.
///
/// Usage: `URLSessionHandler()` or `URLSessionHandler(session: customSession)`
public struct URLSessionHandler: RequestHandler {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func handle(_ request: RawRequest, next: @Sendable (RawRequest) async throws -> RawResponse) async throws -> RawResponse {
        let (data, response) = try await session.data(for: Self.urlRequest(for: request))
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name] = value }
        }
        return RawResponse(status: http.statusCode, headers: headers, data: data)
    }

    /// The `URLRequest` sent for a raw request, ignoring locally cached data.
    static func urlRequest(for request: RawRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        return urlRequest
    }
}
