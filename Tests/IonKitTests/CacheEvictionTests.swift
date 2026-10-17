import Foundation
import Observation
import Testing
import IonKitTesting
@testable import IonKit

/// Delays every request whose URL path ends in `path`, so a test can mutate while that GET is on its way.
private struct DelayHandler: RequestHandler {
    let path: String
    let delay: Duration

    func handle(_ request: RawRequest, next: @Sendable (RawRequest) async throws -> RawResponse) async throws -> RawResponse {
        if request.method == .get, request.url.path.hasSuffix(path) {
            try await Task.sleep(for: delay)
        }
        return try await next(request)
    }
}

@MainActor
@Suite("Cache eviction")
struct CacheEvictionTests {
    let base = MockHandler.defaultBaseURL

    private func person(_ id: String) -> ResourceKey { ResourceKey(type: "person", id: id) }

    /// Whether the store still has an entry, without touching it (`peek` would make it the most recently used).
    private func isCached(_ store: Store, _ key: ResourceKey) -> Bool {
        store.resources.entry(for: key) != nil
    }

    private func requestKey(_ request: Request<JSONAPIDocument>) throws -> RequestKey {
        try RawRequest(request, baseURL: base).key
    }

    /// Answers `GET people/<id>` with a person named after the id.
    private func respondWithPeople(_ mock: MockHandler, _ ids: [String]) {
        for id in ids {
            mock.respond(to: "GET people/\(id)", with: Person(id: id, name: "P\(id)"))
        }
    }

    @Test func withoutACapNothingIsEvicted() async throws {
        let store = Store(baseURL: base, handlers: [MockHandler()])
        store.seed((1...200).map { Person(id: "\($0)", name: "P\($0)") })
        #expect(store.cachedResourceCount == 200)
    }

    @Test func theLeastRecentlyUsedResourceGoesWithItsDocument() async throws {
        let mock = MockHandler()
        respondWithPeople(mock, ["1", "2", "3"])
        let store = Store(baseURL: base, handlers: [mock], maxCachedResources: 2)
        _ = try await store.find(Person.self, id: "1")
        _ = try await store.find(Person.self, id: "2")
        _ = try await store.find(Person.self, id: "3")

        #expect(store.cachedResourceCount == 2)
        #expect(!isCached(store, person("1")))
        #expect(isCached(store, person("2")) && isCached(store, person("3")))
        #expect(store.requests[try requestKey(.find(Person.self, id: "1"))] == nil, "its document goes too")
        #expect(store.requests[try requestKey(.find(Person.self, id: "2"))] != nil)

        _ = try await store.find(Person.self, id: "1")
        #expect(mock.requests(for: "GET people/1").count == 2, "fetched again")
        #expect(!isCached(store, person("2")))
    }

    @Test func aCacheHitMakesAResourceTheMostRecentlyUsed() async throws {
        let mock = MockHandler()
        respondWithPeople(mock, ["1", "2", "3"])
        let store = Store(baseURL: base, handlers: [mock], maxCachedResources: 2)
        _ = try await store.find(Person.self, id: "1")
        _ = try await store.find(Person.self, id: "2")
        _ = try await store.find(Person.self, id: "1")
        #expect(mock.requests.count == 2, "served from the cache")
        _ = try await store.find(Person.self, id: "3")

        #expect(isCached(store, person("1")))
        #expect(!isCached(store, person("2")))

        _ = store.peek(Person.self, id: "1")
        respondWithPeople(mock, ["4"])
        _ = try await store.find(Person.self, id: "4")
        #expect(isCached(store, person("1")), "peek counts as a use")
        #expect(!isCached(store, person("3")))
    }

    @Test func aHeldLiveInstanceIsNeverEvicted() async throws {
        let mock = MockHandler()
        respondWithPeople(mock, ["1", "2", "3"])
        let store = Store(baseURL: base, handlers: [mock], maxCachedResources: 1)
        let ann = try await store.find(Person.self, id: "1")
        _ = try await store.find(Person.self, id: "2")
        _ = try await store.find(Person.self, id: "3")

        #expect(store.cachedResourceCount == 2, "the held one and the newest")
        #expect(isCached(store, person("1")) && isCached(store, person("3")))
        #expect(store.peek(Person.self, id: "1") === ann, "still the one instance")
    }

    @Test func relatedMakesTheRelatedResourcesTheMostRecentlyUsed() async throws {
        let mock = MockHandler()
        respondWithPeople(mock, ["3"])
        let store = Store(baseURL: base, handlers: [mock], maxCachedResources: 3)
        store.seed([Tag(id: "7", name: "friend"), Tag(id: "8", name: "colleague")])
        var ann = Person(id: "1", name: "Ann")
        ann.tags = .ids(["7"])
        store.seed([ann])
        let live = try #require(store.peek(Person.self, id: "1"))
        _ = live.related(\.tags)

        _ = try await store.find(Person.self, id: "3")
        #expect(isCached(store, ResourceKey(type: "tag", id: "7")), "related counts as a use")
        #expect(!isCached(store, ResourceKey(type: "tag", id: "8")))
    }

    @Test func anEvictedRelatedResourceLeavesRelatedAndFires() async throws {
        let mock = MockHandler()
        respondWithPeople(mock, ["3"])
        let store = Store(baseURL: base, handlers: [mock], maxCachedResources: 2)
        store.seed([Tag(id: "7", name: "friend")])
        var ann = Person(id: "1", name: "Ann")
        ann.tags = .ids(["7"])
        store.seed([ann])
        let live = try #require(store.peek(Person.self, id: "1"))
        #expect(live.related(\.tags).count == 1, "read, but not held")

        try await confirmation { changed in
            withObservationTracking { _ = live.related(\.tags) } onChange: { changed() }
            _ = try await store.find(Person.self, id: "3")
        }
        #expect(live.related(\.tags).isEmpty)
        #expect(!isCached(store, ResourceKey(type: "tag", id: "7")))
    }

    @Test func anAliveCollectionKeepsItsResourcesAndDocument() async throws {
        let mock = MockHandler()
        let tag = Fixtures.object(Tag(id: "7", name: "friend"))
        mock.respond(
            to: "GET people?include=tags",
            with: [Person(id: "1", name: "P1", tags: .ids(["7"])), Person(id: "2", name: "P2")], included: [tag]
        )
        respondWithPeople(mock, ["3", "4"])
        let store = Store(baseURL: base, handlers: [mock], maxCachedResources: 1)
        var people: LiveCollection<Person>? = try await store.query(Person.self, include: ["tags"])
        _ = try await store.find(Person.self, id: "3")

        #expect(store.cachedResourceCount == 4)
        #expect(isCached(store, ResourceKey(type: "tag", id: "7")), "included in the collection's first page")
        _ = try await store.query(Person.self, include: ["tags"])
        #expect(mock.requests(for: "GET people?include=tags").count == 1, "the cached first page is still there")
        #expect(people?.items.count == 2)

        people = nil
        _ = try await store.find(Person.self, id: "4")
        #expect(store.cachedResourceCount == 1)
        #expect(isCached(store, person("4")))
        #expect(store.requests[try requestKey(.query(Person.self, include: ["tags"]))] == nil)
    }

    @Test func aResponseLargerThanTheCapIsKeptAndItsIncludedResourcesAreEvictedLater() async throws {
        let mock = MockHandler()
        mock.respond(to: "GET people/42?include=tags", data: try TestFixtures.data("person-single.synthetic"))
        respondWithPeople(mock, ["5"])
        let store = Store(baseURL: base, handlers: [mock], maxCachedResources: 1)
        let ann = try await store.find(Person.self, id: "42", include: ["tags"])
        #expect(store.cachedResourceCount == 3, "the person and two included tags")
        #expect(store.peek(ann.value.tags).count == 2)

        _ = try await store.find(Person.self, id: "5")
        #expect(store.cachedResourceCount == 2, "the held person and the newest one")
        #expect(!isCached(store, ResourceKey(type: "tag", id: "7")))
        #expect(store.requests[try requestKey(.find(Person.self, id: "42", include: ["tags"]))] == nil)
        #expect(ann.value.name == "Ann Example")
    }

    @Test func batchedResolveFetchesAgainWhatALaterBatchEvicted() async throws {
        let mock = MockHandler()
        mock.respond(to: "GET tags?filter[id]=7", with: [Tag(id: "7", name: "friend")])
        mock.respond(to: "GET tags?filter[id]=9", with: [Tag(id: "9", name: "colleague")])
        mock.respond(to: "GET tags/7", with: Tag(id: "7", name: "friend"))
        mock.respond(to: "GET tags/9", with: Tag(id: "9", name: "colleague"))
        let store = Store(baseURL: base, handlers: [mock], maxCachedResources: 1)
        let tags = try await store.resolve(ToMany<Tag>.ids(["7", "9"]), strategy: .batched(batchSize: 1))
        #expect(tags.map(\.value.name) == ["friend", "colleague"])
        #expect(mock.requests(for: "GET tags/7").count == 1, "the second batch evicted the first")
    }

    @Test func loweringTheCapEvictsAtOnce() async throws {
        let store = Store(baseURL: base, handlers: [MockHandler()])
        store.seed((1...5).map { Person(id: "\($0)", name: "P\($0)") })
        store.maxCachedResources = 2
        #expect(store.cachedResourceCount == 2)
        #expect(isCached(store, person("4")) && isCached(store, person("5")))
        store.maxCachedResources = nil
        store.seed([Person(id: "6", name: "P6")])
        #expect(store.cachedResourceCount == 3)
    }

    @Test func aMutatedResourceStaysWhileAnOlderGETIsOnItsWay() async throws {
        let mock = MockHandler()
        mock.respond(to: "GET people/1", with: Person(id: "1", name: "Ann"))
        mock.respond(to: "PATCH people/1", with: Person(id: "1", name: "Ann Saved"))
        respondWithPeople(mock, ["2"])
        let store = Store(
            baseURL: base, handlers: [DelayHandler(path: "people/1", delay: .milliseconds(100)), mock], maxCachedResources: 1
        )
        _ = try await store.find(Person.self, id: "1")
        let stale = Task { try await store.find(Person.self, id: "1", cache: .reload).value.name }
        while store.inflight.isEmpty { await Task.yield() }

        var draft = Draft(try #require(store.peek(Person.self, id: "1")))
        draft.value.name = "Ann Saved"
        try await store.save(&draft)
        _ = try await store.find(Person.self, id: "2")
        #expect(isCached(store, person("1")), "kept: evicting it would let the GET's response revert the save")

        #expect(try await stale.value == "Ann Saved")
        #expect(store.peek(Person.self, id: "1")?.value.name == "Ann Saved")
    }

    @Test func aSnapshotLoadedIntoACappedStoreIsTrimmed() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("snapshot.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let full = Store(baseURL: base, handlers: [MockHandler()], snapshotURL: url)
        full.seed((1...5).map { Person(id: "\($0)", name: "P\($0)") })
        #expect(await full.saveSnapshot())

        let capped = Store(baseURL: base, handlers: [MockHandler()], snapshotURL: url, maxCachedResources: 2)
        #expect(await capped.loadSnapshot())
        #expect(capped.cachedResourceCount == 2)
        #expect(await capped.saveSnapshot())
        #expect(try CacheSnapshot.read(from: url).resources.count == 2, "only what is left is written")
    }
}
