import Foundation
import Synchronization
import Testing
import IonKitTesting
@testable import IonKit

@MainActor
@Suite("v1.x ergonomics")
struct StoreErgonomicsTests {
    let mock: MockHandler
    let store: Store

    init() {
        mock = MockHandler()
        store = Store(baseURL: MockHandler.defaultBaseURL, handlers: [mock])
    }

    // MARK: ETag / 304

    @Test func etagIsSentBackAndA304RefreshesTheEntry() async throws {
        mock.respond(to: "GET people/1", with: Person(id: "1", name: "Ann"), headers: ["ETag": "\"v1\""])
        let live = try await store.find(Person.self, id: "1")
        let key = RequestKey("GET https://mock.ionkit.test/people/1")
        #expect(store.requests[key]?.etag == "\"v1\"")
        let before = try #require(store.requests[key]?.receivedAt)
        #expect(mock.requests.last?.headers["If-None-Match"] == nil)

        try await Task.sleep(for: .milliseconds(5))
        mock.respond(to: "GET people/1", status: 304, headers: ["ETag": "\"v1\""])
        let again = try await store.find(Person.self, id: "1", cache: .reload)
        #expect(again === live)
        #expect(again.value.name == "Ann")
        #expect(mock.requests.count == 2)
        #expect(mock.requests.last?.headers["If-None-Match"] == "\"v1\"")
        let after = try #require(store.requests[key]?.receivedAt)
        #expect(after > before, "a 304 validates the document as of the request")
        #expect(store.requests[key]?.etag == "\"v1\"")

        _ = try await store.find(Person.self, id: "1")
        #expect(mock.requests.count == 2, "fresh again after the 304")
    }

    @Test func a304CarryingCacheHeadersIsHonored() async throws {
        mock.respond(to: "GET people/1", with: Person(id: "1", name: "Ann"), headers: ["ETag": "\"v1\"", "Cache-Control": "max-age=3600"])
        _ = try await store.find(Person.self, id: "1")
        mock.respond(to: "GET people/1", status: 304, headers: ["Cache-Control": "max-age=0"])
        _ = try await store.find(Person.self, id: "1", cache: .reload)
        mock.respond(to: "GET people/1", with: Person(id: "1", name: "Ann v3"))
        let live = try await store.find(Person.self, id: "1")
        #expect(live.value.name == "Ann v3")
        #expect(mock.requests.count == 3, "max-age=0 on the 304 expired the entry at once")
    }

    @Test func a304WithoutAnEntryFetchesUnconditionally() async throws {
        let gate = GateHandler()
        let store = Store(baseURL: MockHandler.defaultBaseURL, handlers: [gate, mock])
        mock.respond(to: "GET people/1", with: Person(id: "1", name: "Ann"), headers: ["ETag": "\"v1\""])
        _ = try await store.find(Person.self, id: "1")

        gate.delayGETs = true
        mock.respond(to: "GET people/1", status: 304)
        mock.respond(to: "GET people/1", with: Person(id: "1", name: "Ann v2"))
        let slow = Task { @MainActor in try await store.find(Person.self, id: "1", cache: .reload) }
        try await Task.sleep(for: .milliseconds(10))
        store.clear()
        gate.open()
        let live = try await slow.value
        #expect(live.value.name == "Ann v2")
        #expect(mock.requests.count == 3)
        #expect(mock.requests[1].headers["If-None-Match"] == "\"v1\"")
        #expect(mock.requests[2].headers["If-None-Match"] == nil, "the retry is unconditional")
    }

    @Test func reloadAfterAMutationDoesNotJoinAnOlderRequest() async throws {
        let gate = GateHandler()
        let store = Store(baseURL: MockHandler.defaultBaseURL, handlers: [gate, mock])
        mock.respond(to: "GET people/1", with: Person(id: "1", name: "Old"))
        let live = try await store.find(Person.self, id: "1")

        gate.delayGETs = true
        let slow = Task { @MainActor in try await store.find(Person.self, id: "1", cache: .reload) }
        try await Task.sleep(for: .milliseconds(10))
        var draft = Draft(live)
        draft.value.name = "New"
        mock.respond(to: "PATCH people/1", with: draft.value)
        try await store.save(&draft)

        mock.respond(to: "GET people/1", with: Person(id: "1", name: "New"))
        let afterSave = Task { @MainActor in try await store.find(Person.self, id: "1", cache: .reload) }
        try await Task.sleep(for: .milliseconds(10))
        gate.open()
        _ = try await slow.value
        _ = try await afterSave.value
        #expect(mock.requests(for: "GET people/1").count == 3, "the post-save reload started its own request")
        #expect(live.value.name == "New")
    }

    @Test func aStaleResponseDoesNotReplaceANewerDocument() async throws {
        let gate = GateHandler()
        let store = Store(baseURL: MockHandler.defaultBaseURL, handlers: [gate, mock])
        mock.respond(to: "GET people", with: [Person(id: "1", name: "Ann")])
        let collection = try await store.query(Person.self)

        gate.delayGETs = true
        let slow = Task { @MainActor in try await store.request(Request<JSONAPIDocument>.query(Person.self, cache: .reload)) }
        try await Task.sleep(for: .milliseconds(10))
        gate.delayGETs = false
        store.requests.invalidate(type: "person")   // the reload below must start its own request, not join `slow`
        mock.respond(to: "GET people", with: [Person(id: "1", name: "Ann"), Person(id: "2", name: "Bob")])
        mock.respond(to: "GET people", with: [Person(id: "1", name: "Ann")])
        try await collection.reload()
        #expect(collection.items.map(\.id) == ["1", "2"])
        gate.open()
        _ = try await slow.value
        #expect(collection.items.map(\.id) == ["1", "2"], "the response to the older request did not win")
        #expect(mock.requests(for: "GET people").count == 3)
    }

    // MARK: Retry

    @Test func retryHandlerRetriesTransientGETFailures() async throws {
        let delays = Mutex<[Duration]>([])
        let retry = RetryHandler(baseDelay: .milliseconds(100), sleep: { duration in delays.withLock { $0.append(duration) } })
        let store = Store(baseURL: MockHandler.defaultBaseURL, handlers: [retry, mock])
        mock.respond(to: "GET people/1", throwing: URLError(.timedOut))
        mock.respond(to: "GET people/1", status: 503, headers: ["Retry-After": "2"])
        mock.respond(to: "GET people/1", with: Person(id: "1", name: "Ann"))
        let live = try await store.find(Person.self, id: "1")
        #expect(live.value.name == "Ann")
        #expect(mock.requests.count == 3)
        let recorded = delays.withLock { $0 }
        #expect(recorded.count == 2)
        #expect(recorded[0] >= .milliseconds(50) && recorded[0] <= .milliseconds(100), "first backoff with jitter")
        #expect(recorded[1] == .seconds(2), "Retry-After wins over the backoff")
    }

    @Test func retryHandlerLeavesTheRestAlone() async throws {
        let retry = RetryHandler(baseDelay: .milliseconds(1), sleep: { _ in })
        let store = Store(baseURL: MockHandler.defaultBaseURL, handlers: [retry, mock])

        mock.respond(to: "GET people/1", throwing: URLError(.notConnectedToInternet))
        await #expect(throws: IonError.self) { _ = try await store.find(Person.self, id: "1") }
        #expect(mock.requests.count == 1, "offline is not transient")

        mock.respond(to: "POST people", status: 503, headers: [:])
        var draft = Draft(new: Person(id: "", name: "New"))
        await #expect(throws: IonError.self) { try await store.save(&draft) }
        #expect(mock.requests(for: "POST people").count == 1, "POST is never retried")

        mock.respond(to: "GET people/2", status: 429, headers: ["Retry-After": "60"])
        do {
            _ = try await store.find(Person.self, id: "2")
            Issue.record("expected 429")
        } catch let error as IonError {
            #expect(error.status == 429)
        }
        #expect(mock.requests(for: "GET people/2").count == 1, "a Retry-After beyond maxDelay is not waited for")

        mock.respond(to: "GET people/3", status: 500, headers: [:])
        await #expect(throws: IonError.self) { _ = try await store.find(Person.self, id: "3") }
        #expect(mock.requests(for: "GET people/3").count == 3, "maxAttempts exhausted")
    }

    @Test func retryAfterParsing() throws {
        #expect(RetryHandler.retryAfter(in: RawResponse(status: 503, headers: ["Retry-After": "3"])) == .seconds(3))
        #expect(RetryHandler.retryAfter(in: RawResponse(status: 503, headers: ["Retry-After": "0"])) == .zero)
        #expect(RetryHandler.retryAfter(in: RawResponse(status: 503)) == nil)
        let dated = RawResponse(status: 503, headers: ["Date": "Thu, 15 Oct 2026 10:00:00 GMT", "Retry-After": "Thu, 15 Oct 2026 10:00:05 GMT"])
        #expect(RetryHandler.retryAfter(in: dated) == .seconds(5))
        #expect(RetryHandler.retryAfter(in: RawResponse(status: 503, headers: ["Retry-After": "soon"])) == nil)
    }

    // MARK: resolve via filter[id]

    @Test func batchedResolveUsesOneQueryPerBatch() async throws {
        store.resolveStrategy = .batched()
        mock.respond(to: "GET tags?filter[id]=7,9", with: [Tag(id: "7", name: "friend"), Tag(id: "9", name: "colleague")])
        let tags = try await store.resolve(ToMany<Tag>.ids(["9", "7", "9"]))
        #expect(tags.map(\.value.name) == ["colleague", "friend", "colleague"])
        #expect(mock.requests.count == 1)

        let again = try await store.resolve(ToMany<Tag>.ids(["7", "9"]))
        #expect(again.count == 2)
        #expect(mock.requests.count == 1, "cached ids need no request")

        mock.respond(to: "GET tags?filter[id]=1", with: [Tag(id: "1", name: "a")])
        mock.respond(to: "GET tags?filter[id]=2", with: [Tag(id: "2", name: "b")])
        let batched = try await store.resolve(ToMany<Tag>.ids(["1", "2"]), strategy: .batched(batchSize: 1))
        #expect(batched.map(\.id) == ["1", "2"])
        #expect(mock.requests.count == 3)
    }

    @Test func batchedResolveFillsGapsOneByOne() async throws {
        mock.respond(to: "GET tags?filter[id]=1,2", with: [Tag(id: "1", name: "a")])
        mock.respond(to: "GET tags/2", with: Tag(id: "2", name: "b"))
        let tags = try await store.resolve(ToMany<Tag>.ids(["1", "2"]), strategy: .batched())
        #expect(tags.map(\.value.name) == ["a", "b"])
        #expect(mock.requests.count == 2)

        mock.respond(to: "GET tags?filter[id]=3,4", with: [Tag(id: "5", name: "e"), Tag(id: "3", name: "c")])
        mock.respond(to: "GET tags/4", with: Tag(id: "4", name: "d"))
        let ignored = try await store.resolve(ToMany<Tag>.ids(["3", "4"]), strategy: .batched())
        #expect(ignored.map(\.value.name) == ["c", "d"])
        #expect(mock.requests.count == 4, "a server that ignores the filter is not asked again")
        #expect(store.peek(Tag.self, id: "5") != nil, "whatever came back is cached anyway")
    }

    @Test func oneByOneStaysTheDefault() async throws {
        mock.respond(to: "GET tags/7", with: Tag(id: "7", name: "friend"))
        mock.respond(to: "GET tags/9", with: Tag(id: "9", name: "colleague"))
        let tags = try await store.resolve(ToMany<Tag>.ids(["7", "9"]))
        #expect(tags.count == 2)
        #expect(mock.requests.count == 2)
        #expect(store.resolveStrategy == .oneByOne)
    }

    // MARK: Multi-page reload

    private func loadTwoPages() async throws -> LiveCollection<Person> {
        mock.respond(to: "GET people?page[size]=2", data: try TestFixtures.data("people-collection.synthetic"))
        mock.respond(to: "GET people?page[number]=2&page[size]=2", with: [Person(id: "44", name: "Cy")], links: Links(["prev": Link(href: "x")]))
        let collection = try await store.query(Person.self, page: ["size": "2"])
        try await collection.loadMore()
        #expect(collection.items.map(\.id) == ["42", "43", "44"])
        #expect(collection.pages.count == 2)
        return collection
    }

    @Test func backgroundReloadRefetchesOnlyTheFirstPage() async throws {
        let collection = try await loadTwoPages()
        mock.respond(to: "GET people?page[size]=2", with: [Person(id: "42", name: "Ann"), Person(id: "50", name: "Dee")],
                     links: Links(["next": Link(href: "https://mock.ionkit.test/people?page[number]=2&page[size]=2")]))
        store.invalidate(type: "person")
        for _ in 0..<50 where !collection.items.map(\.id).contains("50") {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(collection.items.map(\.id) == ["42", "50", "44"], "page 1 replaced, page 2 kept")
        #expect(mock.requests(for: "GET people?page[number]=2&page[size]=2").count == 1)
        #expect(collection.pages.count == 2)
    }

    @Test func reloadFollowsTheFreshNextLinkAndStopsWhenItEnds() async throws {
        let collection = try await loadTwoPages()
        mock.respond(to: "GET people?page[size]=2", with: [Person(id: "42", name: "Ann"), Person(id: "43", name: "Bob")])
        try await collection.reload()
        #expect(collection.items.map(\.id) == ["42", "43"], "no next link any more: one page")
        #expect(collection.pages.count == 1)
        #expect(!collection.hasMore)
        #expect(mock.requests(for: "GET people?page[number]=2&page[size]=2").count == 1)
    }

    @Test func failedLaterPageLeavesTheCollectionAlone() async throws {
        let collection = try await loadTwoPages()
        mock.respond(to: "GET people?page[number]=2&page[size]=2", status: 500, errors: [])
        await #expect(throws: IonError.self) { try await collection.reload() }
        #expect(collection.items.map(\.id) == ["42", "43", "44"])
        #expect(collection.state.isLoaded)
        #expect(!collection.isReloading)
    }

    @Test func concurrentReloadsAreCoalesced() async throws {
        let slow = MockHandler(latency: .milliseconds(20))
        let store = Store(baseURL: MockHandler.defaultBaseURL, handlers: [slow])
        slow.respond(to: "GET people", with: [Person(id: "1", name: "Ann")])
        let collection = try await store.query(Person.self)
        // swiftlint:disable identifier_name - `a` and `b` are the two concurrent reloads
        async let a: Void = collection.reload()
        async let b: Void = collection.reload()
        // swiftlint:enable identifier_name
        try await Task.sleep(for: .milliseconds(5))
        #expect(collection.isReloading)
        _ = try await (a, b)
        #expect(!collection.isReloading)
        #expect(slow.requests.count == 3, "the second reload waits for the first and runs once more")
        #expect(collection.items.count == 1)
    }

    @Test func clearDuringAReloadDiscardsItsResult() async throws {
        let gate = GateHandler()
        let store = Store(baseURL: MockHandler.defaultBaseURL, handlers: [gate, mock])
        mock.respond(to: "GET people", with: [Person(id: "1", name: "Ann")])
        let collection = try await store.query(Person.self)
        gate.delayGETs = true
        let reload = Task { @MainActor in try await collection.reload() }
        try await Task.sleep(for: .milliseconds(10))
        store.clear()
        #expect(collection.items.isEmpty)
        if case .idle = collection.state {} else { Issue.record("expected .idle, got \(collection.state)") }
        gate.open()
        await #expect(throws: IonError.self) { try await reload.value }
        #expect(collection.items.isEmpty, "the pre-logout response did not come back")
        #expect(!collection.isReloading)
    }

    // MARK: Small additions

    @Test func findByRequest() async throws {
        mock.respond(to: "GET me", with: Person(id: "7", name: "Me"))
        // swiftlint:disable:next identifier_name - mirrors the `me` endpoint
        let me = try await store.find(Person.self, request: Request(method: .get, path: "me", op: .find))
        #expect(me.id == "7")
        #expect(store.cachedLive(Person.self, request: Request(method: .get, path: "me", op: .find)) === me)

        mock.respond(to: "GET nobody", document: JSONAPIDocument(one: nil))
        do {
            _ = try await store.find(Person.self, request: Request(method: .get, path: "nobody"))
            Issue.record("expected notFound")
        } catch let error as IonError {
            #expect(error.isNotFound)
        }

        mock.respond(to: "GET people", with: [Person(id: "1", name: "Ann")])
        do {
            _ = try await store.find(Person.self, request: Request(method: .get, path: "people"))
            Issue.record("expected decoding")
        } catch let error as IonError {
            guard case .decoding = error else {
                Issue.record("expected decoding, got \(error)")
                return
            }
        }
    }

    @Test func requestsAreHashable() throws {
        // swiftlint:disable identifier_name - `a` and `b` are the two instances being compared
        let a = Request<JSONAPIDocument>.find(Person.self, id: "1", include: ["tags"])
        let b = Request<JSONAPIDocument>.find(Person.self, id: "1", include: ["tags"])
        // swiftlint:enable identifier_name
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        #expect(a != Request<JSONAPIDocument>.find(Person.self, id: "1"))
        #expect(a != Request<JSONAPIDocument>.find(Person.self, id: "1", include: ["tags"], cache: .reload))
    }

    @Test func localizedDescriptionsArePhrasedForPeople() {
        #expect(IonError.http(status: 404, errors: []).localizedDescription == "This item could not be found.")
        #expect(IonError.http(status: 422, errors: [ErrorObject(detail: "Name is required")]).localizedDescription == "Name is required")
        #expect(IonError.transport(URLError(.notConnectedToInternet)).localizedDescription == "You appear to be offline.")
        #expect(IonError.cancelled.localizedDescription == "The request was cancelled.")
    }
}
