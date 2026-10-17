# IonKit

IonKit lets a SwiftUI app display and edit structs that live behind any [JSON:API 1.1](https://jsonapi.org) server,
with one live-updating instance per resource and an explicit draft/save cycle for edits.

- Define a resource as a plain `Codable` struct plus a type and a path. No schema registry, no code generation.
- Fetch one resource or a collection, with `include`, and get back instances that update whenever any later
  response touches the same resource.
- Edit through a `Draft<T>` copy, save with a PATCH that carries only changed fields, create with POST, delete
  with DELETE; live instances and open collections update from the response.
- Cache in RAM with stale-while-revalidate defaults that honor the server's `Cache-Control` / `Expires`, and
  optionally save it to a file so the next launch renders the last session's data at once.
- Swift 6, Foundation only, no third-party dependencies. Compiles on macOS 15, iOS 18 and Linux.

IonKit borrows [WarpDrive](https://warp-drive.io)'s layering (request chain → cache → live resources), not its
JavaScript mechanics. The full design is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), the canonical source of
truth for the package.

## Installing

IonKit needs Swift 6.2 or later (Xcode 26 on Apple platforms) and runs on macOS 15, iOS 18 and Linux.

```swift
// Package.swift
.package(url: "https://github.com/winsmith/ion-kit.git", from: "1.6.0"),
.target(name: "App", dependencies: [.product(name: "IonKit", package: "ion-kit")]),
.testTarget(name: "AppTests", dependencies: [.product(name: "IonKitTesting", package: "ion-kit")]),
```

## Defining resources

```swift
import IonKit

struct Person: Resource {
    static let resourceType = "person"
    static let collectionPath = "people"     // default would be "persons"

    var id: String
    var name: String
    var birthday: Date?
    var notes: String = ""
    var tags: ToMany<Tag> = .unloaded        // relationships are ids only in v1
    var group: ToOne<Group> = .unloaded

    var initials: String { name.split(separator: " ").compactMap(\.first).map(String.init).joined() }
}

struct Tag: Resource {
    static let resourceType = "tag"
    var id: String
    var name: String
}
```

Stored properties are the JSON:API attributes, `ToOne` / `ToMany` properties are the relationships, and `id` is
the resource id. Custom `CodingKeys`, optionals and computed properties all work as usual. Dates travel as ISO 8601
with or without fractional seconds. Servers that send `snake_case` keys get `ResourceCodec.snakeCase` on the store.

## Setting up a store

```swift
let store = Store(
    baseURL: URL(string: "https://api.example.com/v1")!,
    handlers: [
        RetryHandler(),                      // GETs again after transient failures, with backoff
        BearerTokenHandler { await session.token },
        LoggingHandler(),
        URLSessionHandler(),                 // the last handler performs the request
    ]
)
```

One store per API and session. It is `@MainActor` and `@Observable`, so it can sit in the SwiftUI environment.
The handler chain, `URLSession` and decoding run off the main actor.

## Reading

```swift
struct PersonView: View {
    let id: String

    var body: some View {
        Fetch(Person.self, id: id, include: ["tags"]) { person in
            if person.isDeleted { ContentUnavailableView("Deleted", systemImage: "trash") }
            else { PersonDetail(person: person) }
        }
    }
}
```

`Fetch` takes the `Store` from the environment (`.environment(store)`) or a `store:` argument, shows a
`ProgressView` while loading and a `ContentUnavailableView` with a "Try Again" button on failure (pass `loading:`
and `failed: { error, retry in … }` for your own), and loads again when the id or the store changes. Collections
work the same way: `Fetch(Person.self, sort: ["name"]) { people in List(people.items) { … } }`. Written by hand, the
same screen looks like this:

```swift
struct PersonView: View {
    @Environment(Store.self) private var store
    let id: String
    @State private var person: Live<Person>?
    @State private var error: IonError?

    var body: some View {
        Group {
            if let person { PersonDetail(person: person) }
            else if let error { ErrorView(error) }
            else { ProgressView() }
        }
        .task(id: id) {
            do throws(IonError) {
                person = try await store.find(Person.self, id: id, include: ["tags"])
            } catch .cancelled {                              // the view went away; show nothing
            } catch {
                self.error = error                            // already an IonError
            }
        }
    }
}
```

The `Live<Person>` keeps updating after the task finishes: a later query that includes this person, a save from
another screen, or a `reload()` all flow into the same instance.

```swift
let people = try await store.query(Person.self, filter: ["name": "Ann"], sort: ["-updatedAt"], include: ["tags"])
ForEach(people.items) { live in Row(person: live.value) }   // people.state, people.links, people.meta
try await people.loadMore()                                  // follows links.next
try await people.reload()                                    // every loaded page again, swapped in at once; people.isReloading

let tags = store.peek(person.value.tags)                      // cached instances, no request
let allTags = try await store.resolve(person.value.tags)      // peek, then find the gaps
store.resolveStrategy = .batched()                            // …or one GET tags?filter[id]=7,9 per 50 gaps, if the server filters
```

Every GET goes through the cache first. `DefaultCachePolicy` serves documents younger than one minute as fresh,
serves older ones while refetching in the background, and refetches anything older than a day or past the
server's `max-age` / `Expires`; a document with an `ETag` is refetched with `If-None-Match`, and a 304 just makes it
fresh again. Per request: `cache: .reload`, `cache: .backgroundReload`.

### Persisting the cache

Give the store a file and it can save both caches there and read them back on the next launch, so the first
screen renders from the last session's data before any response arrives and stays readable offline:

```swift
let store = Store(baseURL: url, handlers: […], snapshotURL: URL.cachesDirectory.appending(path: "ionkit.json"))
await store.loadSnapshot()                                  // once, before the first request
…
.onChange(of: scenePhase) { if $0 == .background { Task { await store.saveSnapshot() } } }
```

Restored documents are served at once however old they are and refetched in the background on their first load
(with `If-None-Match` when they had an ETag). Data already in memory wins over the file. A missing or corrupt file,
or one written by another IonKit format or for another base URL, is ignored and the store starts empty; both
methods return `false` instead of throwing. `store.clear()` deletes the file. Encoding, decoding and the atomic
write run off the main actor. IonKit only takes a URL: where the file lives and its file protection are the app's
choice (on iOS a new file gets the app's default protection class).

### Capping the cache

By default the store keeps every resource it has seen for as long as it lives. For a long session over a large
API, cap it:

```swift
let store = Store(baseURL: url, handlers: […], maxCachedResources: 2_000)
```

Past the cap the least recently used resources are evicted, together with every cached document that lists them,
so their next load fetches again. Anything in use stays: a `Live` a view or variable holds, whatever an alive
`LiveCollection` lists, and the response just received. The cap is therefore a target, and the store can hold more
while that much is on screen. Lowering `store.maxCachedResources` evicts at once; a snapshot loaded into a capped
store is trimmed to it.

## Editing

```swift
var draft = Draft(person)                    // from a Live<Person>
draft.value.name = "Ann"
draft.value.tags.ids = ["7", "9"]
let saved = try await store.save(&draft)     // PATCH people/42 with only the changed fields

var fresh = Draft(new: Person(id: "", name: "New"))
try await store.save(&fresh)                 // POST people; fresh.value.id is now the server's id

try await store.delete(person)               // DELETE people/42; person.isDeleted == true (also when it answers 404)
```

On success the response is upserted (the server's version wins), cached queries of the type are invalidated and
alive collections reload. On failure nothing in the cache changes; `IonError.http(status: 422, errors:)` carries
field-level messages via `errors(forAttribute: "name")` when the server sends `source.pointer`. A DELETE answered
with 404 counts as deleted (someone else deleted it first), so `RetryHandler(methods: [.get, .delete])` is safe.

### Bulk saves with `batch`

Every save reloads the alive collections of its type. When many saves happen in a row (an import, a bulk edit),
wrap them in `batch` so each alive collection reloads once, when the batch ends:

```swift
try await store.batch {
    for person in imported {
        var draft = Draft(new: person)
        try await store.save(&draft)                         // upserted at once; lists reload after the batch
    }
}
```

Inside the batch, caches update and deleted items leave lists at once, and a query sees the new data; only the
reloads of alive collections wait. They also run when the closure throws. Saves made concurrently from a task group
inside the closure belong to the batch.

## Errors

Every async method on `Store` and `LiveCollection` uses typed throws, `throws(IonError)`: `.transport`,
`.http(status:errors:)`, `.notFound`, `.decoding`, `.invalidDraft` and `.cancelled`. In a function body a `catch`
receives an `IonError` and `catch .cancelled { }` works as is. Inside a closure, such as SwiftUI's `.task`, Swift
does not infer a `do` block's error type, so write `do throws(IonError) { … }` there, as in the example above;
`catch IonError.cancelled` works everywhere. `error.localizedDescription` is phrased for people ("You appear to be
offline."), `error.description` for logs.

### Signing out on 401 and showing "offline"

Some requests have no caller to catch their error: a background revalidation, the reload of a list after a save, a
`Fetch` showing its own failure view. `store.onError` hears about every request that failed in transport or with an
HTTP error, once per request (retries and shared GETs count once, `.cancelled` never), before any caller does.
`store.lastTransportError` is observable and stays set until a later request reaches the server:

```swift
store.onError = { error, request in
    // A sign-in endpoint answers 401 for a wrong code; that is not a reason to sign out.
    if error.status == 401, !request.url.path.contains("/auth/") { account.signOut() }
}

if store.lastTransportError != nil { Label("Offline", systemImage: "wifi.slash") }
```

Make the handler idempotent: requests already in flight can still report a 401 after the sign-out.

## Testing

`IonKitTesting` ships `MockHandler`, which serves queued responses by `"METHOD path?query"` and records every
request:

```swift
let mock = MockHandler()
mock.respond(to: "GET people/42", with: Person(id: "42", name: "Ann"))
let store = Store(baseURL: MockHandler.defaultBaseURL, handlers: [mock])
let person = try await store.find(Person.self, id: "42")
#expect(mock.requests.count == 1)
mock.respond(to: "GET people/42", throwing: URLError(.timedOut))   // a transport failure, for RetryHandler tests
```

## Building

```sh
swift build
swift test
docker run --rm -v $PWD:/src -w /src swift:6.2 swift test     # Linux, the minimum toolchain
```

## Status

v0.1 (wire format), v0.2 (reads), v0.3 (writes), v1.1 (ergonomics: `Fetch`, multi-page `reload()`, ETag / 304,
`RetryHandler`, batched `resolve`), v1.2 (fixes), v1.3 (`onError`, `lastTransportError`, `batch`, DELETE 404
as success), v1.4 (cache snapshot), v1.5 (typed throws, Swift 6.2 minimum) and v1.6 (LRU eviction) are implemented
and tested against `MockHandler`. Releases are git tags; depend on `from: "1.6.0"`. See the milestone list in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for what comes next.

## License

MIT, see `LICENSE`.
