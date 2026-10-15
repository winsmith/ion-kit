import Foundation
#if canImport(os)
import os
#endif

/// Logs each request's method, URL, status and duration. Uses `os.Logger` where available and `print` elsewhere.
///
/// Usage: `LoggingHandler(level: .bodies)` to also log request and response bodies.
public struct LoggingHandler: RequestHandler {
    public enum Level: Sendable {
        /// Method, URL, status, duration.
        case summary
        /// Also the request and response bodies as UTF-8.
        case bodies
    }

    public let level: Level
    public let sink: (@Sendable (String) -> Void)?

    /// - Parameters:
    ///   - level: how much to log.
    ///   - sink: receives each line instead of the default logger; handy in tests.
    public init(level: Level = .summary, sink: (@Sendable (String) -> Void)? = nil) {
        self.level = level
        self.sink = sink
    }

    public func handle(_ request: RawRequest, next: @Sendable (RawRequest) async throws -> RawResponse) async throws -> RawResponse {
        let start = ContinuousClock.now
        if level == .bodies, let body = request.body, let text = String(data: body, encoding: .utf8) {
            log("→ \(request.method.rawValue) \(request.url.absoluteString)\n\(text)")
        }
        do {
            let response = try await next(request)
            let elapsed = ContinuousClock.now - start
            var line = "\(request.method.rawValue) \(request.url.absoluteString) → \(response.status) (\(elapsed))"
            if level == .bodies, let text = String(data: response.data, encoding: .utf8), !text.isEmpty {
                line += "\n\(text)"
            }
            log(line)
            return response
        } catch {
            let elapsed = ContinuousClock.now - start
            log("\(request.method.rawValue) \(request.url.absoluteString) ✗ \(error) (\(elapsed))")
            throw error
        }
    }

    private func log(_ line: String) {
        if let sink {
            sink(line)
            return
        }
        #if canImport(os)
        Self.logger.debug("\(line, privacy: .public)")
        #else
        print("[IonKit] \(line)")
        #endif
    }

    #if canImport(os)
    private static let logger = Logger(subsystem: "IonKit", category: "requests")
    #endif
}
