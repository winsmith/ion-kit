import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Retries idempotent requests after transient transport failures and retryable statuses, with exponential backoff
/// and jitter. Only GETs are retried by default; a retried DELETE whose first attempt succeeded would answer 404.
///
/// Put it first in the chain so that every attempt runs through the handlers after it (a fresh bearer token, one log
/// line per attempt). Cancellation during a backoff pause propagates as usual.
///
/// Usage: `Store(baseURL: url, handlers: [RetryHandler(), BearerTokenHandler { token }, URLSessionHandler()])`
public struct RetryHandler: RequestHandler {
    /// Attempts in total, the first one included. Default: 3.
    public let maxAttempts: Int
    /// Pause before the second attempt; doubles on every further attempt. Default: 300 ms.
    public let baseDelay: Duration
    /// Longest pause between attempts. A `Retry-After` beyond it is not waited for: the response is returned as is.
    /// Default: 5 s.
    public let maxDelay: Duration
    /// Methods that may be retried. Default: `[.get]`. IonKit's PATCH carries a diff and is idempotent in practice,
    /// so `[.get, .patch]` is a reasonable choice for resilient saves.
    public let methods: Set<HTTPMethod>
    /// Response statuses that are retried. Default: 408, 429, 500, 502, 503, 504.
    public let statuses: Set<Int>
    /// Transport failures that are retried; everything else (offline, bad URL, cancellation) fails at once.
    /// Default: timeouts, lost or refused connections, DNS and TLS failures, malformed server responses.
    public let transportErrors: Set<URLError.Code>
    /// How the handler waits; replaceable in tests. Default: `Task.sleep`.
    public let sleep: @Sendable (Duration) async throws -> Void

    public static let defaultTransportErrors: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
        .secureConnectionFailed, .badServerResponse,
    ]

    public init(
        maxAttempts: Int = 3,
        baseDelay: Duration = .milliseconds(300),
        maxDelay: Duration = .seconds(5),
        methods: Set<HTTPMethod> = [.get],
        statuses: Set<Int> = [408, 429, 500, 502, 503, 504],
        transportErrors: Set<URLError.Code> = RetryHandler.defaultTransportErrors,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.methods = methods
        self.statuses = statuses
        self.transportErrors = transportErrors
        self.sleep = sleep
    }

    public func handle(_ request: RawRequest, next: @Sendable (RawRequest) async throws -> RawResponse) async throws -> RawResponse {
        guard methods.contains(request.method) else { return try await next(request) }
        var attempt = 1
        while true {
            let response: RawResponse
            do {
                response = try await next(request)
            } catch {
                guard attempt < maxAttempts, !Task.isCancelled, isRetryable(error) else { throw error }
                try await sleep(delay(forAttempt: attempt))
                attempt += 1
                continue
            }
            guard attempt < maxAttempts, !Task.isCancelled, statuses.contains(response.status) else { return response }
            var pause = delay(forAttempt: attempt)
            if let retryAfter = Self.retryAfter(in: response) {
                guard retryAfter <= maxDelay else { return response }
                pause = retryAfter
            }
            try await sleep(pause)
            attempt += 1
        }
    }

    // MARK: Internal

    func isRetryable(_ error: any Error) -> Bool {
        switch IonError(error) {
        case .transport(let urlError):
            return transportErrors.contains(urlError.code)
        default:
            return false
        }
    }

    /// `min(maxDelay, baseDelay × 2^(attempt − 1))`, scaled by a random factor in 0.5…1.
    func delay(forAttempt attempt: Int) -> Duration {
        let exponent = min(attempt - 1, 16)
        let scaled = baseDelay * Double(1 << exponent)
        let capped = scaled < maxDelay ? scaled : maxDelay
        return capped * Double.random(in: 0.5...1.0)
    }

    /// `Retry-After` as a delay: a number of seconds, or an HTTP date relative to the response `Date` (or now).
    static func retryAfter(in response: RawResponse) -> Duration? {
        guard let value = response.header("Retry-After")?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Double(value) {
            return .seconds(max(0, seconds))
        }
        if let date = CacheHeaders.parseHTTPDate(value) {
            let reference = response.header("Date").flatMap(CacheHeaders.parseHTTPDate) ?? Date()
            return .seconds(max(0, date.timeIntervalSince(reference)))
        }
        return nil
    }
}
