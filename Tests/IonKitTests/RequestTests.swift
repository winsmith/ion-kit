import Foundation
import Testing
import IonKitTesting
@testable import IonKit

@Suite("Requests")
struct RequestTests {
    let base = URL(string: "https://api.example.com/v1")!

    @Test func resolvesRelativePathAndSortsQuery() throws {
        let request = Request<JSONAPIDocument>.query(Person.self, filter: ["name": "Ann", "age": "3"], sort: ["-updatedAt"], include: ["tags", "group"])
        let raw = try RawRequest(request, baseURL: base)
        #expect(raw.url.absoluteString == "https://api.example.com/v1/people?filter%5Bage%5D=3&filter%5Bname%5D=Ann&include=tags,group&sort=-updatedAt")
        #expect(raw.headers["Accept"] == JSONAPIDocument.mediaType)
        #expect(raw.headers["Content-Type"] == nil)
        #expect(request.cache.types == ["person"])
        #expect(request.op == .query)
    }

    @Test func keepsAbsoluteURLs() throws {
        let request = Request<JSONAPIDocument>(method: .get, path: "https://other.example.com/people?page[number]=2")
        let raw = try RawRequest(request, baseURL: base)
        #expect(raw.url.host == "other.example.com")
        #expect(raw.url.query?.contains("page") == true)
    }

    @Test func findRequest() throws {
        let request = Request<JSONAPIDocument>.find(Person.self, id: "42", include: ["tags"])
        let raw = try RawRequest(request, baseURL: base)
        #expect(raw.url.absoluteString == "https://api.example.com/v1/people/42?include=tags")
        #expect(request.records == [ResourceKey(type: "person", id: "42")])
        #expect(raw.key.value == "GET https://api.example.com/v1/people/42?include=tags")
    }

    @Test func urlSessionHandlerBypassesURLCache() throws {
        let request = Request<JSONAPIDocument>(method: .patch, path: "people/1", body: Data("{}".utf8))
        let raw = try RawRequest(request, baseURL: base)
        let urlRequest = URLSessionHandler.urlRequest(for: raw)
        #expect(urlRequest.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(urlRequest.httpMethod == "PATCH")
        #expect(urlRequest.url == raw.url)
        #expect(urlRequest.httpBody == raw.body)
        #expect(urlRequest.value(forHTTPHeaderField: "Content-Type") == JSONAPIDocument.mediaType)
    }

    @Test func bodyAddsContentType() throws {
        let request = Request<JSONAPIDocument>(method: .post, path: "people", body: Data("{}".utf8))
        let raw = try RawRequest(request, baseURL: base)
        #expect(raw.headers["Content-Type"] == JSONAPIDocument.mediaType)
    }

    @Test func handlerChainRunsInOrderAndTerminates() async throws {
        let mock = MockHandler()
        mock.respond(to: "GET people", status: 204)
        var lines: [String] = []
        let collector = LineCollector()
        let chain = HandlerChain([
            BearerTokenHandler { "secret" },
            LoggingHandler(sink: { collector.append($0) }),
            mock,
        ])
        let raw = try RawRequest(Request<JSONAPIDocument>.query(Person.self), baseURL: MockHandler.defaultBaseURL)
        let response = try await chain.perform(raw)
        #expect(response.status == 204)
        #expect(mock.requests.count == 1)
        #expect(mock.requests[0].headers["Authorization"] == "Bearer secret")
        lines = collector.lines
        #expect(lines.count == 1)
        #expect(lines[0].contains("→ 204"))
    }

    @Test func emptyChainThrowsTransport() async throws {
        let raw = try RawRequest(Request<JSONAPIDocument>.query(Person.self), baseURL: base)
        await #expect(throws: IonError.self) {
            _ = try await HandlerChain([]).perform(raw)
        }
    }

    @Test func mockHandlerMatchesKeysIgnoringQueryOrder() async throws {
        let mock = MockHandler()
        mock.respond(to: "GET people?sort=name&filter[x]=1", with: [Person(id: "1", name: "A")])
        mock.respond(to: "GET people?sort=name&filter[x]=1", status: 404, errors: [ErrorObject(status: "404")])
        let raw = try RawRequest(
            Request<JSONAPIDocument>(method: .get, path: "people", query: [URLQueryItem(name: "filter[x]", value: "1"), URLQueryItem(name: "sort", value: "name")]),
            baseURL: MockHandler.defaultBaseURL
        )
        let first = try await mock.handle(raw) { _ in fatalError() }
        #expect(first.status == 200)
        let second = try await mock.handle(raw) { _ in fatalError() }
        #expect(second.status == 404)
        let third = try await mock.handle(raw) { _ in fatalError() }
        #expect(third.status == 404, "last response repeats")
        #expect(mock.requests(for: "GET people?filter[x]=1&sort=name").count == 3)
    }

    @Test func mockHandlerThrowsForUnknownKey() async throws {
        let mock = MockHandler()
        let raw = try RawRequest(Request<JSONAPIDocument>.find(Person.self, id: "1"), baseURL: MockHandler.defaultBaseURL)
        await #expect(throws: IonError.self) {
            _ = try await mock.handle(raw) { _ in fatalError() }
        }
    }

    @Test func ionErrorHelpers() throws {
        let document = try TestFixtures.document("error-422.synthetic")
        let error = IonError.http(status: 422, errors: document.errors ?? [])
        #expect(error.errors(forAttribute: "name").count == 1)
        #expect(error.errors(forAttribute: "other").isEmpty)
        #expect(error.errors(forRelationship: "group").count == 1)
        #expect(!error.isNotFound)
        #expect(IonError.http(status: 404, errors: []).isNotFound)
        #expect(IonError.notFound(ResourceKey(type: "person", id: "1")).isNotFound)
        if case .cancelled = IonError(CancellationError()) {} else { Issue.record("expected cancelled") }
        if case .cancelled = IonError(URLError(.cancelled)) {} else { Issue.record("expected cancelled") }
        if case .transport = IonError(URLError(.timedOut)) {} else { Issue.record("expected transport") }
    }
}

final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var lines: [String] { lock.withLock { storage } }
    func append(_ line: String) { lock.withLock { storage.append(line) } }
}
