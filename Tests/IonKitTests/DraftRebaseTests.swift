import Foundation
import Testing
import IonKitTesting
@testable import IonKit

/// `Draft.conflicts(against:)` and `Draft.rebase(onto:)`: a reload that changes fields the draft did not touch is not
/// a conflict, and the draft can follow it without losing its edits (v1.9).
@MainActor
@Suite("Draft conflicts and rebase")
struct DraftRebaseTests {
    let mock = MockHandler()
    let store: Store

    init() {
        store = Store(baseURL: MockHandler.defaultBaseURL, handlers: [mock])
    }

    func loadAnn() async throws -> Live<Person> {
        var ann = Person(id: "1", name: "Ann", notes: "n")
        ann.birthday = Date(timeIntervalSince1970: 0)
        ann.group = .id("3")
        ann.tags = .ids(["7"])
        mock.respond(to: "GET people/1", with: ann)
        return try await store.find(Person.self, id: "1")
    }

    @Test func changesTheDraftDidNotMakeAreNotConflicts() async throws {
        let live = try await loadAnn()
        var draft = Draft(live)
        draft.value.name = "Ann B."
        var elsewhere = live.value
        elsewhere.notes = "changed elsewhere"
        elsewhere.friends = .ids(["2"])
        store.seed([elsewhere])
        #expect(draft.isStale(against: live), "isStale still reports any change")
        #expect(draft.conflicts(against: live).isEmpty)
    }

    @Test func anEditedFieldChangedElsewhereIsAConflict() async throws {
        let live = try await loadAnn()
        var draft = Draft(live)
        draft.value.name = "Ann B."
        draft.value.group = .id("4")
        var elsewhere = live.value
        elsewhere.name = "Annie"
        elsewhere.group = .id("5")
        store.seed([elsewhere])
        #expect(draft.conflicts(against: live) == ["name", "group"])

        // The same change on both sides overwrites nothing.
        elsewhere.name = "Ann B."
        elsewhere.group = .id("4")
        store.seed([elsewhere])
        #expect(draft.conflicts(against: live).isEmpty)
    }

    @Test func aRelationshipTheLiveValueNoLongerCarriesIsNoConflict() async throws {
        let live = try await loadAnn()
        var draft = Draft(live)
        draft.value.tags = .ids(["8"])
        var elsewhere = live.value
        elsewhere.tags = .unloaded
        store.seed([elsewhere])
        #expect(draft.conflicts(against: live).isEmpty)
    }

    @Test func rebaseKeepsTheEditsAndTakesEverythingElse() async throws {
        let live = try await loadAnn()
        var draft = Draft(live)
        draft.value.name = "Ann B."
        draft.value.birthday = nil
        var elsewhere = live.value
        elsewhere.notes = "changed elsewhere"
        elsewhere.friends = .ids(["2"])
        store.seed([elsewhere])

        draft.rebase(onto: live)
        #expect(draft.value.name == "Ann B.")
        #expect(draft.value.birthday == nil, "a cleared attribute stays cleared")
        #expect(draft.value.notes == "changed elsewhere")
        #expect(draft.value.friends == .ids(["2"]))
        #expect(draft.original == live.value)
        #expect(!draft.isStale(against: live))
        #expect(draft.hasChanges)

        var saved = draft.value
        saved.updatedAt = Date(timeIntervalSince1970: 100)
        mock.respond(to: "PATCH people/1", with: saved)
        try await store.save(&draft)
        let patch = try #require(mock.requests(for: "PATCH people/1").first?.body)
        let sent = try #require(try JSONAPIDocument.decode(patch).data?.objects.first)
        #expect(sent.attributes == ["name": "Ann B.", "birthday": .null], "only the draft's own edits")
        #expect(sent.relationships.isEmpty)
    }

    @Test func rebaseWithoutEditsFollowsTheLiveValue() async throws {
        let live = try await loadAnn()
        var draft = Draft(live)
        var elsewhere = live.value
        elsewhere.notes = "changed elsewhere"
        store.seed([elsewhere])
        draft.rebase(onto: live)
        #expect(draft.value == live.value)
        #expect(!draft.hasChanges)
    }

    @Test func aNewDraftHasNoConflictsAndDoesNotRebase() async throws {
        let live = try await loadAnn()
        var draft = Draft(new: Person(id: "", name: "Ben"))
        #expect(draft.conflicts(against: live).isEmpty)
        let before = draft.value
        draft.rebase(onto: live)
        #expect(draft.value == before)
        #expect(draft.isNew)
    }
}
