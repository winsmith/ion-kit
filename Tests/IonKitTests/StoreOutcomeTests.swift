import Foundation
import Testing
import IonKitTesting
@testable import IonKit

/// What `onError` saw, in order.
@MainActor
final class ErrorRecorder {
    var calls: [(error: IonError, request: RawRequest)] = []
    var statuses: [Int?] { calls.map(\.error.status) }

    func attach(to store: Store) {
        store.onError = { [weak self] error, request in self?.calls.append((error, request)) }
    }
}

/// What `onOutcome` saw, in order.
@MainActor
final class OutcomeRecorder {
    var outcomes: [RequestOutcome] = []
    var statuses: [Int?] { outcomes.map(\.status) }
    var methods: [HTTPMethod] { outcomes.map(\.request.method) }

    func attach(to store: Store) {
        store.onOutcome = { [weak self] outcome in self?.outcomes.append(outcome) }
    }
}

/// Polls until `condition` holds or about a second passed; background reloads finish on their own schedule.
@MainActor
func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<200 where !condition() {
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
@Suite("Store outcomes")
struct StoreOutcomeTests {
    let mock: MockHandler
    let store: Store
    let recorder = ErrorRecorder()

    init() {
        mock = MockHandler()
        store = Store(baseURL: MockHandler.defaultBaseURL, handlers: [mock])
        recorder.attach(to: store)
    }

    @Test func a401OnFindIsReportedOnceBeforeTheCallerSeesIt() async throws {
        mock.respond(to: "GET people/1", status: 401, errors: [ErrorObject(status: "401", code: "auth.expired")])
        do {
            _ = try await store.find(Person.self, id: "1")
            Issue.record("expected a 401")
        } catch {
            #expect(recorder.statuses == [401])
        }
        #expect(recorder.calls.first?.request.url.path.hasSuffix("people/1") == true)
        #expect(store.lastTransportError == nil, "an HTTP answer is not offline")
    }

    @Test func aBackgroundRevalidationIsReported() async throws {
        store.cachePolicy = DefaultCachePolicy(soft: 0, hard: 3600)
        mock.respond(to: "GET people/1", with: Person(id: "1", name: "Ann"))
        _ = try await store.find(Person.self, id: "1")
        mock.respond(to: "GET people/1", status: 401, errors: [])
        let stale = try await store.find(Person.self, id: "1")
        #expect(stale.value.name == "Ann", "the caller is served from the cache")
        try await eventually { !recorder.calls.isEmpty }
        #expect(recorder.statuses == [401])
    }

    @Test func aCollectionReloadAfterASaveIsReported() async throws {
        mock.respond(to: "GET people", with: [Person]())
        let collection = try await store.query(Person.self)
        mock.respond(to: "POST people", with: Person(id: "9", name: "New"), status: 201)
        mock.respond(to: "GET people", status: 401, errors: [])
        var draft = Draft(new: Person(id: "", name: "New"))
        try await store.save(&draft)
        try await eventually { !recorder.calls.isEmpty }
        #expect(recorder.statuses == [401])
        _ = collection
    }

    @Test func retriesCountAsOneRequest() async throws {
        let retry = RetryHandler(baseDelay: .milliseconds(1), sleep: { _ in })
        let store = Store(baseURL: MockHandler.defaultBaseURL, handlers: [retry, mock])
        recorder.attach(to: store)

        mock.respond(to: "GET people/1", status: 503, errors: [])
        await #expect(throws: IonError.self) { _ = try await store.find(Person.self, id: "1") }
        #expect(mock.requests(for: "GET people/1").count == 3)
        #expect(recorder.statuses == [503])

        mock.respond(to: "GET people/2", throwing: URLError(.timedOut))
        await #expect(throws: IonError.self) { _ = try await store.find(Person.self, id: "2") }
        #expect(mock.requests(for: "GET people/2").count == 3)
        #expect(recorder.calls.count == 2)
        #expect(store.lastTransportError != nil)
    }

    @Test func callersSharingAGETCountAsOne() async throws {
        let mock = MockHandler(latency: .milliseconds(30))
        let store = Store(baseURL: MockHandler.defaultBaseURL, handlers: [mock])
        recorder.attach(to: store)
        mock.respond(to: "GET people/1", status: 500, errors: [])
        async let first: Void = { _ = try? await store.find(Person.self, id: "1") }()
        async let second: Void = { _ = try? await store.find(Person.self, id: "1") }()
        _ = await (first, second)
        #expect(mock.requests(for: "GET people/1").count == 1)
        #expect(recorder.statuses == [500])
    }

    @Test func cancellationIsNotReported() async throws {
        mock.respond(to: "GET people/1", throwing: URLError(.cancelled))
        await #expect(throws: IonError.self) { _ = try await store.find(Person.self, id: "1") }
        #expect(recorder.calls.isEmpty)
        #expect(store.lastTransportError == nil)
    }

    @Test func aTransportErrorSetsOfflineAndAnyAnswerClearsIt() async throws {
        mock.respond(to: "GET people/1", throwing: URLError(.notConnectedToInternet))
        await #expect(throws: IonError.self) { _ = try await store.find(Person.self, id: "1") }
        #expect(store.lastTransportError != nil)
        #expect(recorder.calls.count == 1)

        mock.respond(to: "GET people/2", status: 404, errors: [])
        await #expect(throws: IonError.self) { _ = try await store.find(Person.self, id: "2") }
        #expect(store.lastTransportError == nil, "a 404 proves the server is reachable")

        mock.respond(to: "GET people/3", throwing: URLError(.timedOut))
        await #expect(throws: IonError.self) { _ = try await store.find(Person.self, id: "3") }
        #expect(store.lastTransportError != nil)
        mock.respond(to: "GET people/3", with: Person(id: "3", name: "Cy"))
        _ = try await store.find(Person.self, id: "3")
        #expect(store.lastTransportError == nil)
    }

    @Test func anOlderRequestCannotOverrideANewerOutcome() async throws {
        store.record(.transport(URLError(.timedOut)), status: nil, for: RawRequest(method: .get, url: MockHandler.defaultBaseURL), sentAt: Date(timeIntervalSince1970: 200))
        store.record(nil, status: 200, for: RawRequest(method: .get, url: MockHandler.defaultBaseURL), sentAt: Date(timeIntervalSince1970: 100))
        #expect(store.lastTransportError != nil, "a success sent before the failure does not clear it")
        store.record(nil, status: 200, for: RawRequest(method: .get, url: MockHandler.defaultBaseURL), sentAt: Date(timeIntervalSince1970: 300))
        #expect(store.lastTransportError == nil)
        store.record(.transport(URLError(.timedOut)), status: nil, for: RawRequest(method: .get, url: MockHandler.defaultBaseURL), sentAt: Date(timeIntervalSince1970: 250))
        #expect(store.lastTransportError == nil, "a failure sent before the success does not set it")
        #expect(recorder.calls.count == 2, "onError still hears about every failure")
    }

    @Test func nonDocumentRequestsAreReported() async throws {
        struct Token: Decodable, Sendable { var token: String }
        mock.respond(to: "POST auth/verify", status: 401, errors: [])
        await #expect(throws: IonError.self) {
            _ = try await store.request(Request<Token>(method: .post, path: "auth/verify"))
        }
        #expect(recorder.statuses == [401])
    }

    @Test func aDeleteAnswering404IsNotAnError() async throws {
        mock.respond(to: "GET people/1", with: Person(id: "1", name: "Ann"))
        let live = try await store.find(Person.self, id: "1")
        mock.respond(to: "DELETE people/1", status: 404, errors: [])
        try await store.delete(live)
        #expect(recorder.calls.isEmpty)
    }

    @Test func anUndecodableAnswerClearsOfflineWithoutReporting() async throws {
        mock.respond(to: "GET people/1", throwing: URLError(.timedOut))
        await #expect(throws: IonError.self) { _ = try await store.find(Person.self, id: "1") }
        mock.respond(to: "GET people/1", data: Data("not json".utf8))
        await #expect(throws: IonError.self) { _ = try await store.find(Person.self, id: "1") }
        #expect(store.lastTransportError == nil)
        #expect(recorder.calls.count == 1)
    }
}

@MainActor
@Suite("Store outcomes: onOutcome")
struct StoreOnOutcomeTests {
    let mock: MockHandler
    let store: Store
    let errors = ErrorRecorder()
    let outcomes = OutcomeRecorder()

    init() {
        mock = MockHandler()
        store = Store(baseURL: MockHandler.defaultBaseURL, handlers: [mock])
        errors.attach(to: store)
        outcomes.attach(to: store)
    }

    @Test func aSuccessfulFindIsReportedOnce() async throws {
        mock.respond(to: "GET people/1", with: Person(id: "1", name: "Kaladin"))
        _ = try await store.find(Person.self, id: "1")
        let outcome = try #require(outcomes.outcomes.first)
        #expect(outcomes.outcomes.count == 1)
        #expect(outcome.status == 200)
        #expect(outcome.isSuccess)
        #expect(outcome.request.method == .get)
        #expect(outcome.request.url.path.hasSuffix("people/1"))
        #expect(outcome.finishedAt >= outcome.sentAt)
        #expect(errors.calls.isEmpty)
    }

    @Test func aCacheHitSendsNothingAndReportsNothing() async throws {
        mock.respond(to: "GET people/1", with: Person(id: "1", name: "Kaladin"))
        _ = try await store.find(Person.self, id: "1")
        _ = try await store.find(Person.self, id: "1")
        #expect(outcomes.outcomes.count == 1)
    }

    @Test func aFailureReachesBothHooksAsOneRequest() async throws {
        mock.respond(to: "GET people/1", status: 401, errors: [ErrorObject(status: "401", code: "auth.expired")])
        await #expect(throws: IonError.self) { _ = try await store.find(Person.self, id: "1") }
        #expect(errors.statuses == [401])
        #expect(outcomes.statuses == [401])
        #expect(outcomes.outcomes.first?.error?.status == 401)
        #expect(outcomes.outcomes.first?.isSuccess == false)
    }

    @Test func aTransportFailureHasNoStatus() async throws {
        mock.respond(to: "GET people/1", throwing: URLError(.notConnectedToInternet))
        await #expect(throws: IonError.self) { _ = try await store.find(Person.self, id: "1") }
        let outcome = try #require(outcomes.outcomes.first)
        #expect(outcome.status == nil)
        if case .transport? = outcome.error {} else { Issue.record("expected transport, got \(String(describing: outcome.error))") }
    }

    @Test func createSaveAndDeleteAreReported() async throws {
        mock.respond(to: "POST people", with: Person(id: "1", name: "Shallan"), status: 201)
        var draft = Draft(new: Person(id: "", name: "Shallan"))
        try await store.save(&draft)
        let live = try #require(store.peek(Person.self, key: ResourceKey(type: "person", id: "1")))

        var edit = Draft(live)
        edit.value.name = "Veil"
        mock.respond(to: "PATCH people/1", with: Person(id: "1", name: "Veil"))
        try await store.save(&edit)

        mock.respond(to: "DELETE people/1", status: 204)
        try await store.delete(live)

        #expect(outcomes.methods == [.post, .patch, .delete])
        #expect(outcomes.statuses == [201, 200, 204])
        #expect(outcomes.outcomes.map(\.isSuccess) == [true, true, true])
    }

    @Test func aDeleteAnswering404IsASuccessWithItsStatus() async throws {
        mock.respond(to: "GET people/1", with: Person(id: "1", name: "Szeth"))
        let live = try await store.find(Person.self, id: "1")
        mock.respond(to: "DELETE people/1", status: 404, errors: [])
        try await store.delete(live)
        let outcome = try #require(outcomes.outcomes.last)
        #expect(outcome.request.method == .delete)
        #expect(outcome.status == 404)
        #expect(outcome.isSuccess)
        #expect(errors.calls.isEmpty)
    }

    @Test func retriesCountAsOneOutcome() async throws {
        let retry = RetryHandler(baseDelay: .milliseconds(1), sleep: { _ in })
        let store = Store(baseURL: MockHandler.defaultBaseURL, handlers: [retry, mock])
        outcomes.attach(to: store)
        mock.respond(to: "GET people/1", status: 503, errors: [])
        await #expect(throws: IonError.self) { _ = try await store.find(Person.self, id: "1") }
        #expect(mock.requests(for: "GET people/1").count == 3)
        #expect(outcomes.statuses == [503])
    }

    @Test func callersSharingAGETCountAsOneOutcome() async throws {
        let mock = MockHandler(latency: .milliseconds(30))
        let store = Store(baseURL: MockHandler.defaultBaseURL, handlers: [mock])
        outcomes.attach(to: store)
        mock.respond(to: "GET people/1", with: Person(id: "1", name: "Lift"))
        async let first: Void = { _ = try? await store.find(Person.self, id: "1") }()
        async let second: Void = { _ = try? await store.find(Person.self, id: "1") }()
        _ = await (first, second)
        #expect(mock.requests(for: "GET people/1").count == 1)
        #expect(outcomes.statuses == [200])
    }

    @Test func cancellationIsNotReported() async throws {
        mock.respond(to: "GET people/1", throwing: URLError(.cancelled))
        await #expect(throws: IonError.self) { _ = try await store.find(Person.self, id: "1") }
        #expect(outcomes.outcomes.isEmpty)
    }

    @Test func aBackgroundRevalidationIsReported() async throws {
        store.cachePolicy = DefaultCachePolicy(soft: 0, hard: 3600)
        mock.respond(to: "GET people/1", with: Person(id: "1", name: "Teft"))
        _ = try await store.find(Person.self, id: "1")
        _ = try await store.find(Person.self, id: "1")
        try await eventually { outcomes.outcomes.count == 2 }
        #expect(outcomes.statuses == [200, 200])
    }

    @Test func aCollectionReloadAfterASaveIsReported() async throws {
        mock.respond(to: "GET people", with: [Person]())
        let collection = try await store.query(Person.self)
        mock.respond(to: "POST people", with: Person(id: "9", name: "Lopen"), status: 201)
        mock.respond(to: "GET people", with: [Person(id: "9", name: "Lopen")])
        var draft = Draft(new: Person(id: "", name: "Lopen"))
        try await store.save(&draft)
        try await eventually { outcomes.outcomes.count == 3 }
        #expect(outcomes.methods == [.get, .post, .get])
        _ = collection
    }

    @Test func nonDocumentRequestsAreReported() async throws {
        struct Token: Decodable, Sendable { var token: String }
        mock.respond(to: "POST auth/verify", data: Data(#"{"token":"t"}"#.utf8))
        _ = try await store.request(Request<Token>(method: .post, path: "auth/verify"))
        #expect(outcomes.statuses == [200])
        #expect(outcomes.outcomes.first?.request.url.path.hasSuffix("auth/verify") == true)
    }

    @Test func aBodyThatIsNotADocumentReachesOnOutcomeOnly() async throws {
        mock.respond(to: "GET people/1", data: Data("not json".utf8))
        await #expect(throws: IonError.self) { _ = try await store.find(Person.self, id: "1") }
        #expect(errors.calls.isEmpty, "onError keeps skipping decoding failures")
        let outcome = try #require(outcomes.outcomes.first)
        if case .decoding? = outcome.error {} else { Issue.record("expected decoding, got \(String(describing: outcome.error))") }
    }
}
