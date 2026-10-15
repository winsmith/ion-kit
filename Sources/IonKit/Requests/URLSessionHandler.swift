import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The terminal handler: performs the request with `URLSession` and returns the raw response.
///
/// Usage: `URLSessionHandler()` or `URLSessionHandler(session: customSession)`
public struct URLSessionHandler: RequestHandler {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func handle(_ request: RawRequest, next: @Sendable (RawRequest) async throws -> RawResponse) async throws -> RawResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name] = value }
        }
        return RawResponse(status: http.statusCode, headers: headers, data: data)
    }
}
