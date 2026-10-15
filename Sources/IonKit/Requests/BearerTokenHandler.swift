import Foundation

/// Adds `Authorization: Bearer <token>` when the provider returns a token.
///
/// Usage: `BearerTokenHandler { await session.token }`
public struct BearerTokenHandler: RequestHandler {
    public let token: @Sendable () async -> String?

    public init(token: @escaping @Sendable () async -> String?) {
        self.token = token
    }

    public func handle(_ request: RawRequest, next: @Sendable (RawRequest) async throws -> RawResponse) async throws -> RawResponse {
        var request = request
        if let token = await token(), !token.isEmpty {
            request.headers["Authorization"] = "Bearer \(token)"
        }
        return try await next(request)
    }
}
