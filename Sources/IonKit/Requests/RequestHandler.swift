import Foundation

/// One link in the request chain. A handler may alter the request, short-circuit, retry, or pass it on with `next`.
/// The last handler in a store's chain performs the request (`URLSessionHandler`).
///
/// Usage: `Store(baseURL: url, handlers: [BearerTokenHandler { token }, LoggingHandler(), URLSessionHandler()])`
public protocol RequestHandler: Sendable {
    func handle(_ request: RawRequest, next: @Sendable (RawRequest) async throws -> RawResponse) async throws -> RawResponse
}

/// Runs a request through a chain of handlers.
public struct HandlerChain: Sendable {
    public let handlers: [any RequestHandler]

    public init(_ handlers: [any RequestHandler]) {
        self.handlers = handlers
    }

    /// Calls the first handler, giving each one the rest of the chain as `next`.
    public func perform(_ request: RawRequest) async throws -> RawResponse {
        var next: @Sendable (RawRequest) async throws -> RawResponse = { request in
            throw IonError.transport(URLError(.unsupportedURL, userInfo: [
                NSLocalizedDescriptionKey: "No handler performed the request; add URLSessionHandler() last",
                NSURLErrorFailingURLErrorKey: request.url,
            ]))
        }
        for handler in handlers.reversed() {
            let following = next
            next = { request in try await handler.handle(request, next: following) }
        }
        return try await next(request)
    }
}
