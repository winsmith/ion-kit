import Foundation
import Testing
import IonKitTesting
@testable import IonKit

@MainActor
@Suite("Store writes")
struct StoreWriteTests {
    let mock: MockHandler
    let store: Store

    init() {
        mock = MockHandler()
        store = Store(baseURL: MockHandler.defaultBaseURL, handlers: [mock])
    }

    private func body(of request: RawRequest) throws -> JSONAPIDocument {
        try JSONAPIDocument.decode(try #require(request.body))
    }

    @Test func createPostsFullResourceAndAdoptsServerID() async throws {
        mock.respond(to: "GET people", with: [Person]())
        let collection = try await store.query(Person.self)
        #expect(collection.items.isEmpty)

        var person = Person(id: "", name: "New Person", notes: "hi")
        person.tags = .ids(["7"])
        var draft = Draft(new: person)
        #expect(draft.isNew)
        #expect(draft.hasChanges)
        #expect(draft.value.hasLocalID)

        var created = draft.value
        created.id = "100"
        created.updatedAt = Date(timeIntervalSince1970: 1_792_058_400)
        mock.respond(to: "POST people", with: created, status: 201)
        mock.respond(to: "GET people", with: [created])

        let live = try await store.save(&draft)
        #expect(live.key == ResourceKey(type: "person", id: "100"))
        #expect(live.value.updatedAt != nil, "server-set fields win")
        #expect(draft.value.id == "100")
        #expect(!draft.isNew)
        #expect(!draft.hasChanges)
        #expect(store.peek(Person.self, id: "100") === live)

        let post = try #require(mock.requests(for: "POST people").first)
        #expect(post.headers["Content-Type"] == JSONAPIDocument.mediaType)
        let sent = try #require(try body(of: post).data?.objects.first)
        #expect(sent.type == "person")
        #expect(sent.id == nil)
        #expect(sent.attributes == ["name": "New Person", "notes": "hi"])
        #expect(sent.relationships["tags"]?.data == .many([ResourceIdentifier(type: "tag", id: "7")]))
        #expect(sent.relationships["group"] == nil)

        for _ in 0..<50 where collection.items.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(collection.items.map(\.id) == ["100"], "alive collections reload after a create")
    }

    @Test func updatePatchesOnlyChangedFields() async throws {
        var stored = Person(id: "1", name: "Ann", notes: "n")
        stored.birthday = Date(timeIntervalSince1970: 0)
        mock.respond(to: "GET people/1", with: stored)
        let live = try await store.find(Person.self, id: "1")

        var draft = Draft(live)
        #expect(!draft.hasChanges)
        #expect(!draft.isStale(against: live))
        draft.value.name = "Ann B."
        draft.value.birthday = nil
        draft.value.group.id = "3"
        #expect(draft.hasChanges)

        var updated = draft.value
        updated.notes = "server added"
        mock.respond(to: "PATCH people/1", with: updated)
        let saved = try await store.save(&draft)
        #expect(saved === live)
        #expect(live.value.name == "Ann B.")
        #expect(live.value.notes == "server added", "the live instance shows the server's version")
        #expect(draft.value.notes == "n", "the draft keeps what the user typed")
        #expect(!draft.hasChanges)
        #expect(draft.isStale(against: live))

        let patch = try #require(mock.requests(for: "PATCH people/1").first)
        let sent = try #require(try body(of: patch).data?.objects.first)
        #expect(sent.id == "1")
        #expect(sent.attributes == ["name": "Ann B.", "birthday": .null])
        #expect(sent.relationships["group"]?.data == .one(ResourceIdentifier(type: "group", id: "3")))
        #expect(sent.relationships["tags"] == nil)

        let again = try await store.save(&draft)
        #expect(again === live)
        #expect(mock.requests(for: "PATCH people/1").count == 1, "no changes: no request")
    }

    @Test func updateWith204AppliesTheDraft() async throws {
        mock.respond(to: "GET people/1", with: Person(id: "1", name: "Ann"))
        let live = try await store.find(Person.self, id: "1")
        var draft = Draft(live)
        draft.value.name = "Renamed"
        mock.respond(to: "PATCH people/1", status: 204)
        try await store.save(&draft)
        #expect(live.value.name == "Renamed")
        #expect(!draft.hasChanges)
    }

    @Test func failedSaveLeavesCacheAndDraftAlone() async throws {
        mock.respond(to: "GET people/1", with: Person(id: "1", name: "Ann"))
        let live = try await store.find(Person.self, id: "1")
        var draft = Draft(live)
        draft.value.name = ""
        mock.respond(to: "PATCH people/1", data: try TestFixtures.data("error-422.synthetic"), status: 422)
        do {
            try await store.save(&draft)
            Issue.record("expected 422")
        } catch let error as IonError {
            #expect(error.status == 422)
            #expect(error.errors(forAttribute: "name").first?.detail == "name must not be blank")
        }
        #expect(live.value.name == "Ann")
        #expect(draft.value.name == "")
        #expect(draft.hasChanges)
        draft.revert()
        #expect(draft.value.name == "Ann")
        #expect(!draft.hasChanges)
    }

    @Test func draftReferencingUnsavedResourceIsInvalid() async throws {
        let group = Draft(new: Group(id: "", name: "Family"))
        var person = Draft(new: Person(id: "", name: "Ann"))
        person.value.group.id = group.value.id
        do {
            try await store.save(&person)
            Issue.record("expected invalidDraft")
        } catch {
            guard case IonError.invalidDraft = error else {
                Issue.record("expected invalidDraft, got \(error)")
                return
            }
        }
        #expect(mock.requests.isEmpty)
    }

    @Test func deleteTombstonesAndRemovesFromCollections() async throws {
        mock.respond(to: "GET people", with: [Person(id: "1", name: "Ann"), Person(id: "2", name: "Bob")])
        let collection = try await store.query(Person.self)
        let ann = try #require(collection.items.first)
        mock.respond(to: "DELETE people/1", status: 204)
        mock.respond(to: "GET people", with: [Person(id: "2", name: "Bob")])
        try await store.delete(ann)
        #expect(ann.isDeleted)
        #expect(collection.items.map(\.id) == ["2"], "removed at once")
        #expect(store.peek(Person.self, id: "1") === ann, "the tombstoned instance survives")
        for _ in 0..<50 where mock.requests(for: "GET people").count < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(mock.requests(for: "GET people").count == 2, "collection reloaded")

        mock.respond(to: "GET people", with: [Person(id: "1", name: "Ann"), Person(id: "2", name: "Bob")])
        try await collection.reload()
        #expect(collection.items.map(\.id) == ["1", "2"])
        #expect(collection.items[0] === ann, "a later response revives the same instance")
        #expect(!ann.isDeleted)
    }

    @Test func slowResponseStartedBeforeAMutationDoesNotRevertIt() async throws {
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
        #expect(live.value.name == "New")

        gate.open()
        _ = try await slow.value
        #expect(live.value.name == "New", "the older GET response must not overwrite the PATCH")
    }
}

/// Holds GET requests until opened; everything else passes straight through.
final class GateHandler: RequestHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var _delayGETs = false
    var delayGETs: Bool {
        get { lock.withLock { _delayGETs } }
        set { lock.withLock { _delayGETs = newValue } }
    }

    func open() { lock.withLock { opened = true } }

    func handle(_ request: RawRequest, next: @Sendable (RawRequest) async throws -> RawResponse) async throws -> RawResponse {
        if request.method == .get, delayGETs {
            while !(lock.withLock { opened }) {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        return try await next(request)
    }
}
