import Foundation
import Observation
import Testing
import IonKitTesting
@testable import IonKit

@MainActor
@Suite("Related resources")
struct StoreRelationshipTests {
    let mock: MockHandler
    let store: Store

    init() {
        mock = MockHandler()
        store = Store(baseURL: MockHandler.defaultBaseURL, handlers: [mock])
    }

    /// Seeds person 1 ("Ann") with the given relationships and returns its live instance.
    private func seedAnn(tags: [String] = [], group: ToOne<Group> = .unloaded, in store: Store? = nil) throws -> Live<Person> {
        let store = store ?? self.store
        var ann = Person(id: "1", name: "Ann")
        ann.tags = .ids(tags)
        ann.group = group
        store.seed([ann])
        return try #require(store.peek(Person.self, id: "1"))
    }

    /// Registers Observation tracking on whatever `read` reads, runs `change`, and expects the tracking to fire
    /// `count` times: 1, or 0 for "does not re-render". Tracking is one-shot, so it never fires more than once.
    private func expectChanges(
        _ count: Int = 1,
        reading read: () -> Void,
        during change: () async throws -> Void,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await confirmation(expectedCount: count, sourceLocation: sourceLocation) { changed in
            withObservationTracking { read() } onChange: { changed() }
            try await change()
        }
    }

    // MARK: Values

    @Test func relatedReturnsCachedInstancesInIdOrder() throws {
        store.seed([Tag(id: "7", name: "friend"), Tag(id: "9", name: "colleague")])
        var ann = Person(id: "1", name: "Ann")
        ann.tags = .ids(["9", "7"])
        ann.friends = .ids(["2"])
        store.seed([ann, Person(id: "2", name: "Bob")])
        let live = try #require(store.peek(Person.self, id: "1"))

        let tags = live.related(\.tags)
        #expect(tags.map(\.id) == ["9", "7"])
        #expect(tags.first === store.peek(Tag.self, id: "9"), "the one instance per key")
        #expect(live.related(\.friends).map(\.value.name) == ["Bob"], "a relationship to the same type")
    }

    @Test func relatedSkipsIdsNotInTheCacheAndNeverRequests() throws {
        store.seed([Tag(id: "7", name: "friend")])
        let ann = try seedAnn(tags: ["7", "9"])
        #expect(ann.related(\.tags).map(\.id) == ["7"])
        #expect(mock.requests.isEmpty)
    }

    @Test func relatedSkipsDuplicateIds() throws {
        store.seed([Tag(id: "7", name: "friend"), Tag(id: "9", name: "colleague")])
        let ann = try seedAnn(tags: ["9", "7", "9"])
        #expect(ann.related(\.tags).map(\.id) == ["9", "7"], "safe for ForEach")
        #expect(store.peek(ann.value.tags).count == 3, "peek is unchanged")
    }

    @Test func relatedOfAnUnloadedOrNullRelationshipIsEmpty() throws {
        store.seed([Tag(id: "7", name: "friend")])
        store.seed([Group(id: "3", name: "Family")])
        store.seed([Person(id: "1", name: "Ann")])
        let ann = try #require(store.peek(Person.self, id: "1"))
        #expect(ann.value.tags == .unloaded)
        #expect(ann.related(\.tags).isEmpty)
        #expect(ann.related(\.group) == nil)
        #expect(store.related(ToOne<Group>.null) == nil)
        #expect(store.related(ToMany<Tag>.ids([])).isEmpty)
    }

    @Test func relatedToOneReturnsTheCachedGroup() throws {
        store.seed([Group(id: "3", name: "Family")])
        let ann = try seedAnn(group: .id("3"))
        let group = try #require(ann.related(\.group))
        #expect(group.value.name == "Family")
        #expect(group === store.peek(Group.self, id: "3"))
    }

    @Test func storeRelatedWorksWithADraftsValue() throws {
        store.seed([Tag(id: "7", name: "friend")])
        let ann = try seedAnn()
        var draft = Draft(ann)
        draft.value.tags.ids = ["7"]
        #expect(store.related(draft.value.tags).map(\.value.name) == ["friend"])
        #expect(ann.related(\.tags).isEmpty, "the live instance has not changed")
    }

    // MARK: Observation

    @Test func relatedReRendersWhenATagArrivesLater() async throws {
        store.seed([Tag(id: "7", name: "friend")])
        let ann = try seedAnn(tags: ["7", "9"])
        try await expectChanges(reading: { _ = ann.related(\.tags) }, during: {
            store.seed([Tag(id: "9", name: "colleague")])
        })
        #expect(ann.related(\.tags).map(\.id) == ["7", "9"])
    }

    @Test func relatedReRendersWhenATagArrivesInAnIncludedResponse() async throws {
        let ann = try seedAnn(tags: ["7", "9"])
        #expect(ann.related(\.tags).isEmpty)
        mock.respond(to: "GET people/42?include=tags", data: try TestFixtures.data("person-single.synthetic"))
        try await expectChanges(reading: { _ = ann.related(\.tags) }, during: {
            _ = try await store.find(Person.self, id: "42", include: ["tags"])
        })
        #expect(ann.related(\.tags).map(\.id) == ["7", "9"], "included tags stay raw until related decodes them")
    }

    @Test func relatedReRendersWhenTheParentsIdsChange() async throws {
        store.seed([Tag(id: "7", name: "friend"), Tag(id: "9", name: "colleague")])
        let ann = try seedAnn(tags: ["7"])
        try await expectChanges(reading: { _ = ann.related(\.tags) }, during: {
            _ = try seedAnn(tags: ["7", "9"])
        })
        #expect(ann.related(\.tags).map(\.id) == ["7", "9"])
    }

    @Test func relatedUpdatesAfterResolve() async throws {
        store.seed([Tag(id: "7", name: "friend")])
        let ann = try seedAnn(tags: ["7", "9"])
        mock.respond(to: "GET tags/9", with: Tag(id: "9", name: "colleague"))
        try await expectChanges(reading: { _ = ann.related(\.tags) }, during: {
            _ = try await store.resolve(ann.value.tags)
        })
        #expect(ann.related(\.tags).map(\.value.name) == ["friend", "colleague"])
    }

    @Test func relatedDoesNotFireForAnotherType() async throws {
        store.seed([Tag(id: "7", name: "friend")])
        let ann = try seedAnn(tags: ["7"])
        try await expectChanges(0, reading: { _ = ann.related(\.tags) }, during: {
            store.seed([Group(id: "3", name: "Family")])
            store.seed([Person(id: "2", name: "Bob")])
        })
    }

    @Test func relatedDoesNotFireWhenAnExistingTagChanges() async throws {
        store.seed([Tag(id: "7", name: "friend")])
        let ann = try seedAnn(tags: ["7"])
        try await expectChanges(0, reading: { _ = ann.related(\.tags) }, during: {
            store.seed([Tag(id: "7", name: "best friend")])
        })
        #expect(ann.related(\.tags).first?.value.name == "best friend", "the row observes its own Live")
    }

    @Test func relatedDropsADeletedResourceAndFires() async throws {
        store.seed([Tag(id: "7", name: "friend"), Tag(id: "9", name: "colleague")])
        let ann = try seedAnn(tags: ["7", "9"])
        let friend = try #require(store.peek(Tag.self, id: "7"))
        mock.respond(to: "DELETE tags/7", status: 204)
        try await expectChanges(reading: { _ = ann.related(\.tags) }, during: {
            try await store.delete(friend)
        })
        #expect(ann.related(\.tags).map(\.id) == ["9"])
        #expect(store.peek(ann.value.tags).count == 2, "peek still returns the tombstone")

        try await expectChanges(reading: { _ = ann.related(\.tags) }, during: {
            store.seed([Tag(id: "7", name: "friend")])
        })
        #expect(ann.related(\.tags).first === friend, "revived as the same instance")
    }

    @Test func relatedToOneOfADeletedGroupIsNil() async throws {
        store.seed([Group(id: "3", name: "Family")])
        let ann = try seedAnn(group: .id("3"))
        let family = try #require(ann.related(\.group))
        mock.respond(to: "DELETE groups/3", status: 204)
        try await expectChanges(reading: { _ = ann.related(\.group) }, during: {
            try await store.delete(family)
        })
        #expect(ann.related(\.group) == nil)
        #expect(store.peek(ann.value.group) === family)
    }

    @Test func relatedIsEmptyAndFiresAfterClear() async throws {
        store.seed([Tag(id: "7", name: "friend")])
        let ann = try seedAnn(tags: ["7"])
        try await expectChanges(reading: { _ = ann.related(\.tags) }, during: {
            store.clear()
        })
        #expect(ann.related(\.tags).isEmpty)

        try await expectChanges(reading: { _ = ann.related(\.tags) }, during: {
            store.seed([Tag(id: "7", name: "friend")])
        })
        #expect(ann.related(\.tags).map(\.id) == ["7"], "the same revision keeps working after clear")
    }

    @Test func relatedFiresWhenASnapshotRestoresTheTags() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("snapshot.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let saved = Store(baseURL: MockHandler.defaultBaseURL, handlers: [MockHandler()], snapshotURL: url)
        saved.seed([Tag(id: "7", name: "friend")])
        _ = try seedAnn(tags: ["7"], in: saved)
        #expect(await saved.saveSnapshot())

        let restored = Store(baseURL: MockHandler.defaultBaseURL, handlers: [MockHandler()], snapshotURL: url)
        let ann = try seedAnn(tags: ["7"], in: restored)
        #expect(ann.related(\.tags).isEmpty)
        try await expectChanges(reading: { _ = ann.related(\.tags) }, during: {
            #expect(await restored.loadSnapshot())
        })
        #expect(ann.related(\.tags).map(\.value.name) == ["friend"])
    }

    @Test func relatedOfALiveThatOutlivedItsStoreIsEmpty() throws {
        var owner: Store? = Store(baseURL: MockHandler.defaultBaseURL, handlers: [mock])
        owner?.seed([Tag(id: "7", name: "friend")])
        let ann = try seedAnn(tags: ["7"], in: owner)
        #expect(ann.related(\.tags).count == 1)
        owner = nil
        #expect(ann.store == nil)
        #expect(ann.related(\.tags).isEmpty)
    }
}
