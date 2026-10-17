import Foundation
import Testing
import IonKitTesting
@testable import IonKit

@MainActor
@Suite("Cache snapshot")
struct CacheSnapshotTests {
    let base = MockHandler.defaultBaseURL
    /// A file in a directory that does not exist yet, so every save also exercises directory creation.
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("snapshot.json")

    private func removeFile() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private var fileExists: Bool { FileManager.default.fileExists(atPath: url.path) }

    private func key(_ request: Request<JSONAPIDocument>) throws -> RequestKey {
        try RawRequest(request, baseURL: base).key
    }

    /// A snapshot holding one person and the cached document of `GET people/1`.
    private func personSnapshot(
        _ object: ResourceObject, receivedAt: Date, invalidatedAt: Date? = nil, etag: String? = "\"v1\""
    ) throws -> CacheSnapshot {
        let document = CachedDocument(
            primary: [ResourceKey(type: "person", id: "1")], isCollection: false, op: .find, receivedAt: receivedAt,
            invalidatedAt: invalidatedAt, types: ["person"], etag: etag
        )
        return CacheSnapshot(
            baseURL: base, resources: [CacheSnapshot.Entry(object: object)],
            documents: [try key(.find(Person.self, id: "1")).value: document]
        )
    }

    // MARK: Round trip

    @Test func aSavedStoreRestoresIntoANewOneAndRevalidatesInTheBackground() async throws {
        defer { removeFile() }
        let mockA = MockHandler()
        let storeA = Store(baseURL: base, handlers: [mockA], snapshotURL: url)
        mockA.respond(to: "GET people/42?include=tags", data: try TestFixtures.data("person-single.synthetic"))
        _ = try await storeA.find(Person.self, id: "42", include: ["tags"])
        mockA.respond(to: "GET people?page[size]=2", data: try TestFixtures.data("people-collection.synthetic"))
        let next = Links(["next": Link(href: "https://mock.ionkit.test/people?page[number]=2&page[size]=2")])
        // After the delete the server no longer lists 43; the collection's background reload fetches this.
        mockA.respond(to: "GET people?page[size]=2", with: [Person(id: "42", name: "Ann Example")], links: next)
        mockA.respond(to: "GET people?page[number]=2&page[size]=2", with: [Person(id: "44", name: "Cy")])
        let collectionA = try await storeA.query(Person.self, page: ["size": "2"])
        try await collectionA.loadMore()
        mockA.respond(to: "DELETE people/43", status: 204)
        try await storeA.delete(collectionA.items[1])
        try await eventually { mockA.requests(for: "GET people?page[size]=2").count == 2 && !collectionA.isReloading }
        #expect(collectionA.items.map(\.id) == ["42", "44"])
        #expect(await storeA.saveSnapshot())
        #expect(fileExists)
        let json = try String(contentsOf: url, encoding: .utf8)
        #expect(!json.contains("isRestored"))
        #expect(!json.contains("mutationSequence"))

        let mockB = MockHandler(latency: .milliseconds(50))
        let storeB = Store(baseURL: base, handlers: [mockB], snapshotURL: url)
        #expect(await storeB.loadSnapshot())
        #expect(storeB.cachedResourceCount == storeA.cachedResourceCount)
        #expect(storeB.peek(Person.self, id: "42")?.value.name == "Ann Example")
        #expect(storeB.peek(Person.self, id: "44")?.value.name == "Cy")
        #expect(storeB.peek(Tag.self, id: "7")?.value.name == "friend")
        #expect(storeB.peek(Group.self, id: "3")?.value.name == "Family")
        #expect(storeB.peek(Person.self, id: "43")?.isDeleted == true, "the tombstone survives")

        mockB.respond(to: "GET people?page[size]=2", with: [Person(id: "42", name: "Ann Renamed")], links: next)
        let collectionB = try await storeB.query(Person.self, page: ["size": "2"])
        #expect(collectionB.items.map(\.value.name) == ["Ann Example"], "served from the snapshot at once")
        #expect(collectionB.hasMore)
        #expect(mockB.requests.isEmpty)
        let pageKey = try key(.query(Person.self, page: ["size": "2"]))
        #expect(storeB.requests[pageKey]?.isRestored == true)

        try await eventually { collectionB.items.first?.value.name == "Ann Renamed" }
        #expect(collectionB.items.first?.value.name == "Ann Renamed", "one background revalidation")
        #expect(mockB.requests.count == 1)
        #expect(storeB.requests[pageKey]?.isRestored == false)
        _ = try await storeB.query(Person.self, page: ["size": "2"])
        #expect(mockB.requests.count == 1, "fresh within soft expiry")
    }

    // MARK: Staleness

    @Test func aRestoredDocumentIsStaleWhateverItsAge() async throws {
        defer { removeFile() }
        let twoDaysAgo = Date().addingTimeInterval(-2 * 24 * 60 * 60)
        try CacheSnapshot.write(try personSnapshot(Fixtures.object(Person(id: "1", name: "Ann")), receivedAt: twoDaysAgo), to: url)
        let mock = MockHandler(latency: .milliseconds(20))
        let store = Store(baseURL: base, handlers: [mock], cachePolicy: DefaultCachePolicy(soft: 3600), snapshotURL: url)
        #expect(await store.loadSnapshot())
        let documentKey = try key(.find(Person.self, id: "1"))

        mock.respond(to: "GET people/1", status: 304, headers: ["ETag": "\"v1\""])
        let person = try await store.find(Person.self, id: "1")
        #expect(person.value.name == "Ann", "served at once though older than the hard expiry")
        #expect(mock.requests.isEmpty)
        try await eventually { store.requests[documentKey]?.isRestored == false }
        #expect(store.requests[documentKey]?.isRestored == false, "the 304 clears isRestored")
        #expect(mock.requests.count == 1)
        #expect(mock.requests.first?.headers["If-None-Match"] == "\"v1\"")

        _ = try await store.find(Person.self, id: "1")
        #expect(mock.requests.count == 1, "fresh after the 304")
    }

    @Test func aRestoredDocumentInvalidatedBeforeTheSaveIsExpired() async throws {
        defer { removeFile() }
        let receivedAt = Date().addingTimeInterval(-10)
        let snapshot = try personSnapshot(
            Fixtures.object(Person(id: "1", name: "Ann")), receivedAt: receivedAt, invalidatedAt: receivedAt.addingTimeInterval(0.001)
        )
        try CacheSnapshot.write(snapshot, to: url)
        let mock = MockHandler()
        let store = Store(baseURL: base, handlers: [mock], snapshotURL: url)
        #expect(await store.loadSnapshot())

        mock.respond(to: "GET people/1", with: Person(id: "1", name: "Ann Fetched"))
        let person = try await store.find(Person.self, id: "1")
        #expect(person.value.name == "Ann Fetched", "waited for the network")
        #expect(mock.requests.count == 1)
    }

    // MARK: Discarded files

    @Test func aMissingOrUnusableFileIsDiscarded() async throws {
        defer { removeFile() }
        let entry = CacheSnapshot.Entry(object: Fixtures.object(Person(id: "1", name: "Ann")))
        let store = Store(baseURL: base, handlers: [MockHandler()], snapshotURL: url)
        #expect(await !store.loadSnapshot(), "missing file")
        #expect(store.cachedResourceCount == 0)

        let garbage = Data("not json".utf8)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try garbage.write(to: url)
        #expect(await !store.loadSnapshot(), "corrupt file")
        #expect(store.cachedResourceCount == 0)
        #expect(try Data(contentsOf: url) == garbage, "the file is left as it was")

        let unusable = [
            CacheSnapshot(formatVersion: 2, baseURL: base, resources: [entry]),
            CacheSnapshot(baseURL: URL(string: "https://other.ionkit.test/")!, resources: [entry]),
        ]
        for snapshot in unusable {
            try CacheSnapshot.write(snapshot, to: url)
            let before = try Data(contentsOf: url)
            #expect(await !store.loadSnapshot())
            #expect(store.cachedResourceCount == 0)
            #expect(try Data(contentsOf: url) == before)
        }
    }

    @Test func withoutASnapshotURLNothingHappens() async throws {
        let store = Store(baseURL: base, handlers: [MockHandler()])
        store.seed([Person(id: "1", name: "Ann")])
        #expect(await !store.saveSnapshot())
        #expect(await !store.loadSnapshot())
        store.clear()
        #expect(store.snapshotTail == nil)
    }

    // MARK: Ordering with RAM and clear()

    @Test func aLateLoadDoesNotOverwriteNewerData() async throws {
        defer { removeFile() }
        try CacheSnapshot.write(try personSnapshot(Fixtures.object(Person(id: "1", name: "Old")), receivedAt: Date()), to: url)
        let mock = MockHandler()
        let store = Store(baseURL: base, handlers: [mock], snapshotURL: url)
        mock.respond(to: "GET people/1", with: Person(id: "1", name: "New"))
        let person = try await store.find(Person.self, id: "1")

        #expect(await store.loadSnapshot())
        #expect(person.value.name == "New")
        #expect(store.peek(Person.self, id: "1")?.value.name == "New")
        #expect(store.requests[try key(.find(Person.self, id: "1"))]?.isRestored == false)
        _ = try await store.find(Person.self, id: "1")
        #expect(mock.requests.count == 1, "the document from RAM is still fresh")
    }

    @Test func clearDeletesTheFile() async throws {
        defer { removeFile() }
        let store = Store(baseURL: base, handlers: [MockHandler()], snapshotURL: url)
        store.seed([Person(id: "1", name: "Ann")])
        #expect(await store.saveSnapshot())
        #expect(fileExists)
        store.clear()
        _ = await store.snapshotTail?.value
        #expect(!fileExists)
    }

    @Test func aSaveFollowedByClearDoesNotResurrectTheFile() async throws {
        defer { removeFile() }
        let store = Store(baseURL: base, handlers: [MockHandler()], snapshotURL: url)
        store.seed([Person(id: "1", name: "Ann")])
        let saving = Task { await store.saveSnapshot() }
        while store.snapshotTail == nil { await Task.yield() }
        store.clear()
        #expect(await saving.value)
        _ = await store.snapshotTail?.value
        #expect(!fileExists)
    }

    @Test func clearDuringALoadDropsIt() async throws {
        defer { removeFile() }
        try CacheSnapshot.write(try personSnapshot(Fixtures.object(Person(id: "1", name: "Ann")), receivedAt: Date()), to: url)
        let store = Store(baseURL: base, handlers: [MockHandler()], snapshotURL: url)
        // Holds the file work back, so the load is still reading when clear() runs.
        store.snapshotTail = Task.detached {
            try? await Task.sleep(for: .milliseconds(50))
            return true
        }
        let loading = Task { await store.loadSnapshot() }
        await Task.yield()
        store.clear()
        #expect(await !loading.value)
        #expect(store.cachedResourceCount == 0)
        #expect(store.peek(Person.self, id: "1") == nil)
    }

    // MARK: Struct changes

    @Test func aRestoredEntryThatNoLongerDecodesIsFetchedAgain() async throws {
        defer { removeFile() }
        let undecodable = ResourceObject(type: "person", id: "1", attributes: [:])   // `name` is required
        var snapshot = try personSnapshot(undecodable, receivedAt: Date())
        // The query lists another undecodable person, so the `find` below does not repair it first.
        snapshot.resources.append(CacheSnapshot.Entry(object: ResourceObject(type: "person", id: "2", attributes: [:])))
        snapshot.documents[try key(.query(Person.self)).value] = CachedDocument(
            primary: [ResourceKey(type: "person", id: "2")], isCollection: true, op: .query, receivedAt: Date(),
            types: ["person"], etag: "\"list\""
        )
        try CacheSnapshot.write(snapshot, to: url)
        let mock = MockHandler()
        let store = Store(baseURL: base, handlers: [mock], snapshotURL: url)
        #expect(await store.loadSnapshot())
        #expect(store.peek(Person.self, id: "1") == nil)

        mock.respond(to: "GET people/1", with: Person(id: "1", name: "Ann"))
        let person = try await store.find(Person.self, id: "1")
        #expect(person.value.name == "Ann")
        #expect(mock.requests.count == 1)
        #expect(mock.requests.first?.headers["If-None-Match"] == nil, "the old ETag is dropped with the document")

        mock.respond(to: "GET people", with: [Person(id: "1", name: "Ann"), Person(id: "2", name: "Bob")])
        let people = try await store.query(Person.self)
        #expect(people.items.map(\.id) == ["1", "2"])
        #expect(mock.requests.count == 2)
        #expect(mock.requests.last?.headers["If-None-Match"] == nil)
    }
}
