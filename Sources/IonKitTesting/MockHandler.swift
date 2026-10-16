import Foundation
import IonKit
import Synchronization

/// A terminal handler for tests: serves queued responses by `"METHOD path?query"` key and records every request.
///
/// Keys match method, path and sorted query exactly, relative to `baseURL`. Each key holds a FIFO queue; once a
/// queue is drained its last served response is repeated. An unmatched key throws `IonError.transport`.
///
/// Usage:
/// ```swift
/// let mock = MockHandler()
/// mock.respond(to: "GET people/42", with: Person(id: "42", name: "Ann"))
/// let store = Store(baseURL: MockHandler.defaultBaseURL, handlers: [mock])
/// ```
public final class MockHandler: RequestHandler {
    /// The base URL tests pass to their store; keys are relative to it.
    public static let defaultBaseURL = URL(string: "https://mock.ionkit.test/")!

    public let baseURL: URL
    public let codec: ResourceCodec
    /// Delay before each response, to test in-flight deduplication and cancellation. Default: none.
    public let latency: Duration?

    /// What a queued entry does when served.
    private enum Outcome {
        case response(RawResponse)
        case failure(any Error)
    }

    private struct State {
        var queues: [String: [Outcome]] = [:]
        var lastServed: [String: Outcome] = [:]
        var requests: [RawRequest] = []
    }

    private let state = Mutex(State())

    public init(baseURL: URL = MockHandler.defaultBaseURL, codec: ResourceCodec = .default, latency: Duration? = nil) {
        self.baseURL = baseURL
        self.codec = codec
        self.latency = latency
    }

    /// Every request that reached the handler, in order.
    public var requests: [RawRequest] {
        state.withLock { $0.requests }
    }

    /// The requests matching a key, in order.
    public func requests(for key: String) -> [RawRequest] {
        let wanted = Self.normalize(key)
        return requests.filter { self.key(for: $0) == wanted }
    }

    /// Forgets recorded requests (queued responses stay).
    public func clearRequests() {
        state.withLock { $0.requests.removeAll() }
    }

    // MARK: Queuing responses

    /// Queues a raw response for a key such as `"GET people?include=tags"`.
    public func respond(to key: String, with response: RawResponse) {
        let normalized = Self.normalize(key)
        state.withLock { $0.queues[normalized, default: []].append(.response(response)) }
    }

    /// Queues a failure: the handler throws `error` instead of answering, as `URLSessionHandler` would for a
    /// transport problem. Like any queued entry it is repeated once the queue is drained, so a failure queued last
    /// fails every later request for the key; queue a response after it for "fail, then succeed".
    ///
    /// Usage: `mock.respond(to: "GET people", throwing: URLError(.timedOut))`
    public func respond(to key: String, throwing error: any Error) {
        let normalized = Self.normalize(key)
        state.withLock { $0.queues[normalized, default: []].append(.failure(error)) }
    }

    /// Queues a JSON:API document.
    public func respond(to key: String, document: JSONAPIDocument, status: Int = 200, headers: [String: String] = [:]) {
        let data = try! document.encoded()
        var headers = headers
        if headers["Content-Type"] == nil { headers["Content-Type"] = JSONAPIDocument.mediaType }
        respond(to: key, with: RawResponse(status: status, headers: headers, data: data))
    }

    /// Queues a single-resource document built through the codec.
    public func respond<T: Resource>(
        to key: String, with value: T, included: [ResourceObject] = [], links: Links? = nil,
        meta: [String: JSONValue]? = nil, status: Int = 200, headers: [String: String] = [:]
    ) {
        let object = try! codec.encode(value)
        respond(to: key, document: JSONAPIDocument(one: object, included: included, links: links, meta: meta), status: status, headers: headers)
    }

    /// Queues a collection document built through the codec.
    public func respond<T: Resource>(
        to key: String, with values: [T], included: [ResourceObject] = [], links: Links? = nil,
        meta: [String: JSONValue]? = nil, status: Int = 200, headers: [String: String] = [:]
    ) {
        let objects = values.map { try! codec.encode($0) }
        respond(to: key, document: JSONAPIDocument(many: objects, included: included, links: links, meta: meta), status: status, headers: headers)
    }

    /// Queues an error document with the given status.
    public func respond(to key: String, status: Int, errors: [ErrorObject], headers: [String: String] = [:]) {
        respond(to: key, document: JSONAPIDocument(errors: errors), status: status, headers: headers)
    }

    /// Queues an empty response, e.g. `status: 204`.
    public func respond(to key: String, status: Int, headers: [String: String] = [:]) {
        respond(to: key, with: RawResponse(status: status, headers: headers))
    }

    /// Queues a response whose body is a fixture's bytes.
    public func respond(to key: String, data: Data, status: Int = 200, headers: [String: String] = [:]) {
        var headers = headers
        if headers["Content-Type"] == nil { headers["Content-Type"] = JSONAPIDocument.mediaType }
        respond(to: key, with: RawResponse(status: status, headers: headers, data: data))
    }

    // MARK: RequestHandler

    public func handle(_ request: RawRequest, next: @Sendable (RawRequest) async throws -> RawResponse) async throws -> RawResponse {
        let key = key(for: request)
        let outcome: Outcome? = state.withLock { state in
            state.requests.append(request)
            if var queue = state.queues[key], !queue.isEmpty {
                let outcome = queue.removeFirst()
                state.queues[key] = queue
                state.lastServed[key] = outcome
                return outcome
            }
            return state.lastServed[key]
        }
        guard let outcome else {
            throw IonError.transport(URLError(.unsupportedURL, userInfo: [
                NSLocalizedDescriptionKey: "MockHandler has no response for \"\(key)\"",
                NSURLErrorFailingURLErrorKey: request.url,
            ]))
        }
        if let latency {
            try await Task.sleep(for: latency)
        }
        try Task.checkCancellation()
        switch outcome {
        case .response(let response): return response
        case .failure(let error): throw error
        }
    }

    // MARK: Keys

    /// The key a raw request matches: method plus its URL relative to `baseURL`, query sorted.
    public func key(for request: RawRequest) -> String {
        var base = baseURL.absoluteString
        if !base.hasSuffix("/") { base += "/" }
        var urlString = request.url.absoluteString
        if urlString.hasPrefix(base) {
            urlString = String(urlString.dropFirst(base.count))
        }
        return Self.normalize("\(request.method.rawValue) \(urlString)")
    }

    /// Sorts the query of a `"METHOD path?query"` key so that argument order never matters.
    static func normalize(_ key: String) -> String {
        let parts = key.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return key }
        let method = parts[0].uppercased()
        var path = String(parts[1])
        if path.hasPrefix("/") { path.removeFirst() }
        guard var components = URLComponents(string: path) else { return "\(method) \(path)" }
        if let items = components.queryItems, !items.isEmpty {
            components.queryItems = items.sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
        }
        return "\(method) \(components.string ?? path)"
    }
}
