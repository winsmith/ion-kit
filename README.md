# IonKit

IonKit lets a SwiftUI app display and edit structs that live behind any [JSON:API 1.1](https://jsonapi.org) server,
with one live-updating instance per resource and an explicit draft/save cycle for edits.

- Define a resource as a plain `Codable` struct plus a type and a path. No schema registry, no code generation.
- Fetch one resource or a collection, with `include`, and get back instances that update whenever any later
  response touches the same resource.
- Edit through a `Draft<T>` copy, save with a PATCH that carries only changed fields, create with POST, delete
  with DELETE; live instances and open collections update from the response.
- Cache in RAM with stale-while-revalidate defaults that honor the server's `Cache-Control` / `Expires`.
- Swift 6, Foundation only, no third-party dependencies. Compiles on macOS 15, iOS 18 and Linux.

IonKit borrows [WarpDrive](https://warp-drive.io)'s layering (request chain → cache → live resources), not its
JavaScript mechanics. The full design lives in the architecture document linked from `CLAUDE.md`.

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
            do { person = try await store.find(Person.self, id: id, include: ["tags"]) }
            catch IonError.cancelled { }                      // the view went away; show nothing
            catch { self.error = error as? IonError }
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
try await people.reload()

let tags = store.peek(person.value.tags)                      // cached instances, no request
let allTags = try await store.resolve(person.value.tags)      // peek, then find the gaps
```

Every GET goes through the cache first. `DefaultCachePolicy` serves documents younger than one minute as fresh,
serves older ones while refetching in the background, and refetches anything older than a day or past the
server's `max-age` / `Expires`. Per request: `cache: .reload`, `cache: .backgroundReload`.

## Editing

```swift
var draft = Draft(person)                    // from a Live<Person>
draft.value.name = "Ann"
draft.value.tags.ids = ["7", "9"]
let saved = try await store.save(&draft)     // PATCH people/42 with only the changed fields

var fresh = Draft(new: Person(id: "", name: "New"))
try await store.save(&fresh)                 // POST people; fresh.value.id is now the server's id

try await store.delete(person)               // DELETE people/42; person.isDeleted == true
```

On success the response is upserted (the server's version wins), cached queries of the type are invalidated and
alive collections reload. On failure nothing in the cache changes; `IonError.http(status: 422, errors:)` carries
field-level messages via `errors(forAttribute: "name")` when the server sends `source.pointer`.

## Errors

Every store method throws `IonError` only: `.transport`, `.http(status:errors:)`, `.notFound`, `.decoding`,
`.invalidDraft` and `.cancelled`.

## Testing

`IonKitTesting` ships `MockHandler`, which serves queued responses by `"METHOD path?query"` and records every
request:

```swift
let mock = MockHandler()
mock.respond(to: "GET people/42", with: Person(id: "42", name: "Ann"))
let store = Store(baseURL: MockHandler.defaultBaseURL, handlers: [mock])
let person = try await store.find(Person.self, id: "42")
#expect(mock.requests.count == 1)
```

## Building

```sh
swift build
swift test
docker run --rm -v $PWD:/src -w /src swift:6.1 swift test     # Linux
```

## Status

v0.1 (wire format), v0.2 (reads) and v0.3 (writes) are implemented and tested against `MockHandler`. See the
milestone list in the architecture document for what comes next.

## License

MIT, see `LICENSE`.
