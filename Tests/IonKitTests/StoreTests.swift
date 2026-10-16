import Foundation
import Testing
import IonKitTesting
@testable import IonKit

@MainActor
@Suite("Store reads")
struct StoreReadTests {
    let mock: MockHandler
    let store: Store

    init() {
        mock = MockHandler()
        store = Store(baseURL: MockHandler.defaultBaseURL, handlers: [mock])
    }

    @Test func findReturnsLiveAndCachesIncluded() async throws {
        mock.respond(to: "GET people/42?include=tags", data: try TestFixtures.data("person-single.synthetic"))
        let person = try await store.find(Person.self, id: "42", include: ["tags"])
        #expect(person.key == ResourceKey(type: "person", id: "42"))
        #expect(person.value.name == "Ann Example")
        #expect(person.id == "42")
        #expect(person.raw.meta?["revision"]?.intValue == 3)
        #expect(!person.isDeleted)

        let tags = store.peek(person.value.tags)
        #expect(tags.map(\.value.name) == ["friend", "colleague"])
        #expect(store.peek(person.value.group) == nil)
        #expect(store.peek(Tag.self, id: "missing") == nil)
        #expect(store.cachedResourceCount == 3)

        let again = try await store.find(Person.self, id: "42", include: ["tags"])
        #expect(again === person, "one instance per key")
        #expect(mock.requests.count == 1, "second find is a cache hit")
    }

    @Test func findWithReloadHitsNetwork() async throws {
        mock.respond(to: "GET people/1", with: Person(id: "1", name: "A"))
        let first = try await store.find(Person.self, id: "1")
        mock.respond(to: "GET people/1", with: Person(id: "1", name: "B"))
        let second = try await store.find(Person.self, id: "1", cache: .reload)
        #expect(first === second)
        #expect(second.value.name == "B")
        #expect(mock.requests.count == 2)
    }

    @Test func laterResponseUpdatesSameInstance() async throws {
        mock.respond(to: "GET people/1", with: Person(id: "1", name: "Ann"))
        let live = try await store.find(Person.self, id: "1")
        let before = live.updatedAt
        mock.respond(to: "GET people", with: [Person(id: "1", name: "Ann Renamed"), Person(id: "2", name: "Bob")])
        let collection = try await store.query(Person.self)
        #expect(collection.items.first === live)
        #expect(live.value.name == "Ann Renamed")
        #expect(live.updatedAt >= before)
    }

    @Test func unchangedResponseDoesNotTouchUpdatedAt() async throws {
        mock.respond(to: "GET people/1", with: Person(id: "1", name: "Ann"))
        let live = try await store.find(Person.self, id: "1")
        let stamp = live.updatedAt
        _ = try await store.find(Person.self, id: "1", cache: .reload)
        #expect(live.updatedAt == stamp)
    }

    @Test func httpErrorsAndNullData() async throws {
        mock.respond(to: "GET people/404", status: 404, errors: [ErrorObject(status: "404", title: "Not found")])
        await #expect(throws: IonError.self) {
            _ = try await store.find(Person.self, id: "404")
        }
        do {
            _ = try await store.find(Person.self, id: "404")
        } catch let error as IonError {
            #expect(error.isNotFound)
            #expect(error.status == 404)
            #expect(error.errorObjects.first?.title == "Not found")
        }
        mock.respond(to: "GET people/null", document: JSONAPIDocument(one: nil))
        do {
            _ = try await store.find(Person.self, id: "null")
            Issue.record("expected notFound")
        } catch {
            guard case IonError.notFound(let key) = error else {
                Issue.record("expected notFound, got \(error)")
                return
            }
            #expect(key == ResourceKey(type: "person", id: "null"))
        }
    }

    @Test func undecodablePrimaryFailsTheRequest() async throws {
        mock.respond(to: "GET people/1", document: JSONAPIDocument(one: ResourceObject(type: "person", id: "1", attributes: ["notes": ""])))
        do {
            _ = try await store.find(Person.self, id: "1")
            Issue.record("expected decoding error")
        } catch {
            guard case IonError.decoding(let key, _) = error else {
                Issue.record("expected decoding, got \(error)")
                return
            }
            #expect(key == ResourceKey(type: "person", id: "1"))
        }
    }

    @Test func transportErrorForUnknownRoute() async throws {
        do {
            _ = try await store.find(Person.self, id: "nowhere")
            Issue.record("expected transport error")
        } catch {
            guard case IonError.transport = error else {
                Issue.record("expected transport, got \(error)")
                return
            }
        }
    }

    @Test func queryLoadsCollectionAndPaginates() async throws {
        mock.respond(to: "GET people?page[size]=2", data: try TestFixtures.data("people-collection.synthetic"))
        mock.respond(to: "GET people?page[number]=2&page[size]=2", with: [Person(id: "44", name: "Cy")], links: Links(["prev": Link(href: "x")]))
        let collection = try await store.query(Person.self, page: ["size": "2"])
        #expect(collection.state.isLoaded)
        #expect(collection.items.map(\.id) == ["42", "43"])
        #expect(collection.meta["page"]?["total"]?.intValue == 5)
        #expect(collection.hasMore)
        #expect(store.peek(Group.self, id: "3")?.value.name == "Family")
        #expect(store.peek(collection.items[1].value.group)?.value.name == "Family")

        try await collection.loadMore()
        #expect(collection.items.map(\.id) == ["42", "43", "44"])
        #expect(!collection.hasMore)
        try await collection.loadMore()
        #expect(mock.requests.count == 2, "no next link: loadMore is a no-op")

        try await collection.reload()
        #expect(collection.items.map(\.id) == ["42", "43", "44"], "reload refetches every loaded page")
        #expect(mock.requests.count == 4)
        #expect(collection.pages.count == 2)
        #expect(!collection.isReloading)
    }

    @Test func sameQuerySharesOneCollection() async throws {
        mock.respond(to: "GET people?filter[name]=Ann&sort=name", with: [Person(id: "1", name: "Ann")])
        let a = try await store.query(Person.self, filter: ["name": "Ann"], sort: ["name"])
        let b = try await store.query(Person.self, filter: ["name": "Ann"], sort: ["name"], include: [])
        #expect(a === b)
        #expect(mock.requests.count == 1)
    }

    @Test func customPathQuery() async throws {
        mock.respond(to: "GET groups/3/members?include=tags", with: [Person(id: "1", name: "Ann")])
        let members = try await store.query(Person.self, path: "groups/3/members", include: ["tags"])
        #expect(members.items.map(\.id) == ["1"])
    }

    @Test func queryFailureSetsState() async throws {
        mock.respond(to: "GET people", status: 500, errors: [])
        do {
            _ = try await store.query(Person.self)
            Issue.record("expected failure")
        } catch let error as IonError {
            #expect(error.status == 500)
        }
        mock.respond(to: "GET people", with: [Person(id: "1", name: "Ann")])
        let collection = try await store.query(Person.self)
        #expect(collection.state.isLoaded)
        #expect(collection.items.count == 1)
    }

    @Test func inFlightRequestsAreDeduplicated() async throws {
        let slow = MockHandler(latency: .milliseconds(50))
        let store = Store(baseURL: MockHandler.defaultBaseURL, handlers: [slow])
        slow.respond(to: "GET people/1", with: Person(id: "1", name: "Ann"))
        async let first = store.find(Person.self, id: "1")
        async let second = store.find(Person.self, id: "1")
        let (a, b) = try await (first, second)
        #expect(a === b)
        #expect(slow.requests.count == 1)
        #expect(store.inflight.isEmpty)
    }

    @Test func staleEntriesAreServedAndRefetched() async throws {
        store.cachePolicy = DefaultCachePolicy(soft: 0, hard: 3600)
        mock.respond(to: "GET people/1", with: Person(id: "1", name: "Ann"))
        let live = try await store.find(Person.self, id: "1")
        mock.respond(to: "GET people/1", with: Person(id: "1", name: "Ann v2"))
        let served = try await store.find(Person.self, id: "1")
        #expect(served === live)
        #expect(served.value.name == "Ann", "served from cache before the background refetch lands")
        for _ in 0..<50 where live.value.name == "Ann" {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(live.value.name == "Ann v2")
        #expect(mock.requests.count == 2)
    }

    @Test func expiredEntriesWaitForNetwork() async throws {
        store.cachePolicy = NoCachePolicy()
        mock.respond(to: "GET people/1", with: Person(id: "1", name: "Ann"))
        _ = try await store.find(Person.self, id: "1")
        _ = try await store.find(Person.self, id: "1")
        #expect(mock.requests.count == 2)
    }

    @Test func serverCacheHeadersAreHonored() async throws {
        mock.respond(to: "GET people/1", with: Person(id: "1", name: "Ann"), headers: ["Cache-Control": "max-age=0"])
        _ = try await store.find(Person.self, id: "1")
        _ = try await store.find(Person.self, id: "1")
        #expect(mock.requests.count == 2, "max-age=0 expires at once")

        mock.respond(to: "GET people/2", with: Person(id: "2", name: "Bob"), headers: ["Cache-Control": "no-store"])
        _ = try await store.find(Person.self, id: "2")
        #expect(store.requests[RequestKey("GET https://mock.ionkit.test/people/2")] == nil, "no-store skips the request cache")
        #expect(store.peek(Person.self, id: "2") != nil, "resources are still upserted")

        mock.respond(to: "GET people/3", with: Person(id: "3", name: "Cy"), headers: ["Cache-Control": "max-age=3600"])
        _ = try await store.find(Person.self, id: "3")
        _ = try await store.find(Person.self, id: "3")
        #expect(mock.requests(for: "GET people/3").count == 1)
    }

    @Test func invalidateTypeReloadsAliveCollections() async throws {
        mock.respond(to: "GET people", with: [Person(id: "1", name: "Ann")])
        let collection = try await store.query(Person.self)
        mock.respond(to: "GET people", with: [Person(id: "1", name: "Ann"), Person(id: "2", name: "Bob")])
        store.invalidate(type: "person")
        for _ in 0..<50 where collection.items.count == 1 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(collection.items.map(\.id) == ["1", "2"])

        mock.respond(to: "GET people", with: [Person(id: "1", name: "Ann")])
        collection.autoRefresh = false
        store.invalidate(type: "person")
        try await Task.sleep(for: .milliseconds(20))
        #expect(collection.items.count == 2, "autoRefresh off: no reload")
        _ = try await store.query(Person.self)
        #expect(collection.items.count == 1, "but the entry is expired, so the next query refetches")
    }

    @Test func collectionSurvivesItsStore() async throws {
        var store: Store? = Store(baseURL: MockHandler.defaultBaseURL, handlers: [mock])
        mock.respond(to: "GET people", with: [Person(id: "1", name: "Ann")])
        let collection = try await store!.query(Person.self)
        store!.invalidate(type: "person")   // schedules a background reload that will outlive the store
        store = nil
        try await Task.sleep(for: .milliseconds(30))
        #expect(collection.store == nil)
        #expect(collection.items.map(\.id) == ["1"], "keeps what it last showed")
        await #expect(throws: IonError.self) { try await collection.reload() }
        #expect(collection.items.map(\.id) == ["1"])
    }

    @Test func resolveFetchesOnlyMissingIDs() async throws {
        store.seed([Tag(id: "7", name: "friend")])
        mock.respond(to: "GET tags/9", with: Tag(id: "9", name: "colleague"))
        var person = Person(id: "1", name: "Ann")
        person.tags = .ids(["7", "9"])
        let tags = try await store.resolve(person.tags)
        #expect(tags.map(\.value.name) == ["friend", "colleague"])
        #expect(mock.requests.count == 1)
        person.group = .id("3")
        mock.respond(to: "GET groups/3", with: Group(id: "3", name: "Family"))
        let group = try await store.resolve(person.group)
        #expect(group?.value.name == "Family")
        #expect(try await store.resolve(ToOne<Group>.null) == nil)
    }

    @Test func customRequestsUpsertAndReturnDocuments() async throws {
        mock.respond(to: "GET people/1/relationships/tags", document: JSONAPIDocument(many: [ResourceObject(type: "tag", id: "7", attributes: ["name": "x"])]))
        let document = try await store.request(Request(method: .get, path: "people/1/relationships/tags"))
        #expect(document.data?.objects.map(\.id) == ["7"])
        #expect(store.peek(Tag.self, id: "7")?.value.name == "x")

        struct Status: Decodable { let ok: Bool }
        mock.respond(to: "GET status", with: RawResponse(status: 200, data: Data(#"{"ok": true}"#.utf8)))
        let status: Status = try await store.request(Request<Status>(method: .get, path: "status"))
        #expect(status.ok)
    }

    @Test func clearDropsEverything() async throws {
        mock.respond(to: "GET people", with: [Person(id: "1", name: "Ann")])
        let collection = try await store.query(Person.self)
        store.clear()
        #expect(store.cachedResourceCount == 0)
        #expect(collection.items.isEmpty)
        #expect(store.peek(Person.self, id: "1") == nil)
    }

    @Test func cancelledCallerSeesCancelled() async throws {
        let slow = MockHandler(latency: .milliseconds(100))
        let store = Store(baseURL: MockHandler.defaultBaseURL, handlers: [slow])
        slow.respond(to: "GET people/1", with: Person(id: "1", name: "Ann"))
        let task = Task { @MainActor in
            do {
                _ = try await store.find(Person.self, id: "1")
                return "loaded"
            } catch {
                if case IonError.cancelled = error { return "cancelled" }
                return "other: \(error)"
            }
        }
        try await Task.sleep(for: .milliseconds(10))
        task.cancel()
        #expect(await task.value == "cancelled")
    }
}
