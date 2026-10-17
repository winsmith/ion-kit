import Foundation
import Testing
import IonKitTesting
@testable import IonKit

@MainActor
@Suite("Store batch")
struct StoreBatchTests {
    let mock: MockHandler
    let store: Store

    init() {
        mock = MockHandler()
        store = Store(baseURL: MockHandler.defaultBaseURL, handlers: [mock])
    }

    private func queuePosts(_ count: Int) {
        for index in 1...count {
            mock.respond(to: "POST people", with: Person(id: "\(index)", name: "P\(index)"), status: 201)
        }
    }

    /// Lets background reloads that were started run to completion.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(50))
    }

    @Test func savesInABatchReloadAliveCollectionsOnce() async throws {
        mock.respond(to: "GET people", with: [Person]())
        let collection = try await store.query(Person.self)
        queuePosts(5)
        mock.respond(to: "GET people", with: (1...5).map { Person(id: "\($0)", name: "P\($0)") })

        try await store.batch {
            for index in 1...5 {
                var draft = Draft(new: Person(id: "", name: "P\(index)"))
                try await store.save(&draft)
            }
            #expect(mock.requests(for: "GET people").count == 1, "no reload while the batch runs")
        }
        try await eventually { collection.items.count == 5 }
        try await settle()
        #expect(mock.requests(for: "POST people").count == 5)
        #expect(mock.requests(for: "GET people").count == 2, "the initial load plus one reload")
    }

    @Test func concurrentSavesInsideABatch() async throws {
        mock.respond(to: "GET people", with: [Person]())
        let collection = try await store.query(Person.self)
        queuePosts(8)
        mock.respond(to: "GET people", with: [Person(id: "1", name: "P1")])

        let store = self.store
        await store.batch {
            await Self.saveConcurrently(8, in: store)
        }
        try await eventually { !collection.items.isEmpty }
        try await settle()
        #expect(mock.requests(for: "POST people").count == 8)
        #expect(mock.requests(for: "GET people").count == 2)
    }

    private static func saveConcurrently(_ count: Int, in store: Store) async {
        await withTaskGroup(of: Void.self) { group in
            for index in 1...count {
                group.addTask { await save(Person(id: "", name: "P\(index)"), in: store) }
            }
        }
    }

    private static func save(_ person: Person, in store: Store) async {
        var draft = Draft(new: person)
        _ = try? await store.save(&draft)
    }

    @Test func aThrowingBodyStillReloads() async throws {
        struct Stop: Error {}
        mock.respond(to: "GET people", with: [Person]())
        let collection = try await store.query(Person.self)
        queuePosts(2)
        mock.respond(to: "GET people", with: [Person(id: "1", name: "P1")])

        await #expect(throws: Stop.self) {
            try await store.batch {
                for _ in 1...2 {
                    var draft = Draft(new: Person(id: "", name: "P"))
                    try await store.save(&draft)
                }
                throw Stop()
            }
        }
        try await eventually { !collection.items.isEmpty }
        try await settle()
        #expect(mock.requests(for: "GET people").count == 2)
    }

    @Test func nestedBatchesReloadWhenTheOutermostEnds() async throws {
        mock.respond(to: "GET people", with: [Person]())
        let collection = try await store.query(Person.self)
        queuePosts(2)
        mock.respond(to: "GET people", with: [Person(id: "1", name: "P1")])

        try await store.batch {
            try await store.batch {
                var draft = Draft(new: Person(id: "", name: "P1"))
                try await store.save(&draft)
            }
            try await settle()
            #expect(mock.requests(for: "GET people").count == 1, "the inner batch does not flush")
            var draft = Draft(new: Person(id: "", name: "P2"))
            try await store.save(&draft)
        }
        try await eventually { !collection.items.isEmpty }
        try await settle()
        #expect(mock.requests(for: "GET people").count == 2)
    }

    @Test func autoRefreshIsReadWhenTheBatchEnds() async throws {
        mock.respond(to: "GET people", with: [Person]())
        let collection = try await store.query(Person.self)
        queuePosts(1)

        try await store.batch {
            var draft = Draft(new: Person(id: "", name: "P1"))
            try await store.save(&draft)
            collection.autoRefresh = false
        }
        try await settle()
        #expect(mock.requests(for: "GET people").count == 1)
    }

    @Test func cachedQueriesGoStaleAtOnce() async throws {
        mock.respond(to: "GET people?sort=name", with: [Person]())
        _ = try await store.query(Person.self, sort: ["name"])
        queuePosts(1)

        try await store.batch {
            var draft = Draft(new: Person(id: "", name: "P1"))
            try await store.save(&draft)
            mock.respond(to: "GET people?sort=name", with: [Person(id: "1", name: "P1")])
            let fresh = try await store.query(Person.self, sort: ["name"])
            #expect(fresh.items.map(\.id) == ["1"], "a query inside the batch does not see the pre-save result")
        }
    }

    @Test func deletesLeaveListsAtOnceAndReloadLater() async throws {
        mock.respond(to: "GET people", with: [Person(id: "1", name: "Ann"), Person(id: "2", name: "Ben")])
        let collection = try await store.query(Person.self)
        let ann = try #require(collection.items.first)
        mock.respond(to: "DELETE people/1", status: 204)
        mock.respond(to: "GET people", with: [Person(id: "2", name: "Ben")])

        try await store.batch {
            try await store.delete(ann)
            #expect(collection.items.map(\.id) == ["2"])
            try await settle()
            #expect(mock.requests(for: "GET people").count == 1)
        }
        try await eventually { mock.requests(for: "GET people").count == 2 }
        #expect(mock.requests(for: "GET people").count == 2)
    }

    @Test func clearInsideABatchDropsThePendingReloads() async throws {
        mock.respond(to: "GET people", with: [Person]())
        let collection = try await store.query(Person.self)
        queuePosts(1)

        try await store.batch {
            var draft = Draft(new: Person(id: "", name: "P1"))
            try await store.save(&draft)
            store.clear()
        }
        try await settle()
        #expect(mock.requests(for: "GET people").count == 1)
        #expect(!collection.state.isLoaded && collection.items.isEmpty)
    }

    @Test func eachTouchedTypeReloadsOnce() async throws {
        mock.respond(to: "GET people", with: [Person]())
        mock.respond(to: "GET tags", with: [Tag]())
        let people = try await store.query(Person.self)
        let tags = try await store.query(Tag.self)
        queuePosts(2)
        mock.respond(to: "POST tags", with: Tag(id: "7", name: "t"), status: 201)
        mock.respond(to: "GET people", with: [Person(id: "1", name: "P1")])
        mock.respond(to: "GET tags", with: [Tag(id: "7", name: "t")])

        try await store.batch {
            for _ in 1...2 {
                var person = Draft(new: Person(id: "", name: "P"))
                try await store.save(&person)
            }
            var tag = Draft(new: Tag(id: "", name: "t"))
            try await store.save(&tag)
        }
        try await eventually { !people.items.isEmpty && !tags.items.isEmpty }
        try await settle()
        #expect(mock.requests(for: "GET people").count == 2)
        #expect(mock.requests(for: "GET tags").count == 2)
    }
}
