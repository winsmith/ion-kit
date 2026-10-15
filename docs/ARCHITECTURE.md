# IonKit Architecture Design

2026-10-15 · Daniel Jilg

> This file is the canonical source of truth for IonKit's design. It started as a Claude Docs document on
> 2026-10-15 and was moved into the repository, with the revisions listed under
> [Implementation notes](#implementation-notes-2026-10-15), after v0.1–v0.3 landed. Consumers of the library start
> at [Current state of the code](#current-state-of-the-code-v03-2026-10-15). Change the code and this file in the
> same pull request.

## Purpose and goals

IonKit is a Swift package that lets a SwiftUI app display and edit structs that live behind any JSON:API server, with one live-updating instance per resource and an explicit draft/save cycle for edits. The Village app (a Vapor 5 JSON:API server, one user per graph, online-only writes) is its first consumer and the source of its fixtures, but nothing in the package is Village-specific: the target is JSON:API 1.1 as a client, with the spec's optional members optional in IonKit too.

**Goals for v1**

- Define a resource as a plain `Codable` struct plus a resource type and a path; no runtime schema registry, no code generation.
- Fetch one resource or a collection, with `include`, and get back instances that update whenever any later response touches the same resource.
- Edit through a `Draft<T>` copy, save with a PATCH that carries only changed fields, create with POST, delete with DELETE; the live instances and open collections update from the response.
- Work against any JSON:API 1.1 server: every top-level and resource-level member is parsed, key casing is configurable, and features the spec leaves optional (`source.pointer`, `links.next`, `Cache-Control`) improve behavior when present and break nothing when absent.
- Cache in RAM with stale-while-revalidate defaults (serve cached, refetch in the background) that honor the server's cache headers.
- Compile on macOS 15, iOS 18 and Linux (Swift 6, Foundation only, no third-party dependencies).
- Stay small: the v1 core is one target of roughly 2,000–3,000 lines that two people, or an agent with this document, can hold in their head.

**Non-goals for v1** (some return in later milestones, see Development milestones)

- Offline writes, optimistic UI, conflict resolution.
- Typed, live-resolving relationship properties; relationship inverses; polymorphic relationships.
- Persistent cache on disk.
- Sparse fieldsets and field-level merging of partial resources.
- Code generation or macros for resource definitions.
- Multi-tenant or admin-only resource types; v1 only needs to not block them.
- Any transport other than HTTP(S) via `URLSession`.

## WarpDrive (Polaris mode) and its Swift counterparts

IonKit borrows WarpDrive's layering (request chain → cache → live resources), not its JavaScript mechanics. WarpDrive's Polaris mode is still marked preview in its v5 line and becomes the default in v6; the concepts below are stable, the API details are from the 5.10 alpha source ([polaris-mode guide](https://warp-drive.io/guides/the-manual/schemas/resources/polaris-mode), [caching guide](https://warp-drive.io/guides/the-manual/caching/index), [requests guide](https://warp-drive.io/guides/the-manual/requests/index)).

| WarpDrive concept | What it does there | IonKit equivalent |
| --- | --- | --- |
| `Store` | Coordinator owning request manager, cache, schema service, notifications | `Store` — one `@MainActor` object per API/session, owns cache + client |
| `RequestManager` + handlers | Chain of responsibility; each handler gets `(context, next)`; `Fetch` last | `RequestHandler` protocol chain ending in `URLSessionHandler`; auth and logging are handlers |
| `CacheHandler` | First in chain; cache hit vs fetch vs background refetch; dedupes in-flight requests; writes every response into the cache | The cache step inside the store, above the handler chain, with the same decision order; handlers never see cache hits |
| `JSONAPICache` | Documents stored by `RequestKey` (replace), resources by `ResourceKey` (upsert per field), local edits as a diff over remote state | `ResourceCache`: identity map `[ResourceKey: Entry]` (raw resource object + lazily decoded `Live<T>`) + `[RequestKey: CachedDocument]`; local edits live in `Draft`, not in the cache (v1) |
| `SchemaService` + `ResourceSchema` fields (`field`, `derived`, `belongsTo`/`hasMany` in LinksMode, `schema-object`, `alias`, `@local`) | Runtime registry of field definitions driving a Proxy | Swift types replace the registry: a `Codable` struct conforming to `Resource` (`static resourceType`, `id`, attributes, `ToOne`/`ToMany` relationships); derived = computed properties; transformations = `Codable` |
| `ReactiveResource` (immutable Proxy) | Live, read-only instance re-rendering on remote changes | `Live<T>`: `@Observable` final class holding the current `T` value, updated by cache upserts |
| `ReactiveDocument` (`data`, `included`, `links`, `meta`, `errors`) + `next()`/`prev()` | Hydrated response; pagination follows links | `LiveCollection<T>` observable with `reload()` / `loadMore()` over `links` |
| `checkout()` → editable copy, `op: updateRecord` + `records:` → `didCommit` | Local edits isolated from the live instance; server response becomes new remote state | `Draft<T>` (plain mutable struct copy) + `store.save(&draft)`; response upserted into cache, which updates every `Live<T>` |
| `store.createRecord` | New record with client `lid` before server `id` | `Draft(new:)` with a client-local placeholder id that is never sent; the `Live<T>` is created from the server's response |
| Request builders (`findRecord`, `query`, `createRecord`, `updateRecord`, `deleteRecord`) | Plain request descriptions typed with `withReactiveResponse<T>` | `Request<Response>` structs; builders on the store (`store.find(T.self, id:)`, `store.query(T.self, …)`) |
| `cacheOptions` (`key`, `reload`, `backgroundReload`, `types`) | Per-request cache control and invalidation tags | `CacheOptions` struct on `Request`; `types` invalidates cached collection queries after a mutation |
| `DefaultCachePolicy` (hard/soft expiry, honors `Cache-Control`, `Expires`) | Decides stale vs expired per `RequestKey` | `CachePolicy` protocol + `DefaultCachePolicy(soft: 1 min, hard: 24 h)`, honoring `Cache-Control` / `Expires` from v1 |
| `Type` brand (`[Type]: 'user'`) | TypeScript-only inference of resource type string | Not needed — Swift generics carry the type |
| `Future` (Promise + `abort()`, `getStream()`) | Cancellable request | `Task` + `async throws(IonError)`; cancellation via Swift structured concurrency |
| Notifications (`remote` / `local` channels) | Field-level signals | `Observation` framework; the cache assigns `live.value` only when it changed |
| `@warp-drive/ember` `<Request>` / `@warp-drive/react` | Framework bindings with loading/error/content states | SwiftUI: `LoadState` enum (v1) + a `Fetch<T>` view helper (v1.x) |

Three WarpDrive behaviors are worth copying exactly: (1) every response is written to the cache even when the request itself is not cacheable, which is how POST/PATCH/DELETE update live instances; (2) in-flight requests with the same key are deduplicated; (3) a successful create invalidates cached queries tagged with that resource type.

Two things IonKit deliberately does not copy: the runtime schema registry (Swift's type system does that job at compile time) and storing local edits inside the cache as a diff (a `Draft<T>` value is simpler and enough for online-only writes).

## Core architecture

Four layers, one direction of calls and one direction of updates: views call the store, the store runs requests through the handler chain, responses are decoded and upserted into the resource cache, and the cache notifies the live instances that views observe.

```mermaid
flowchart LR
    View["SwiftUI view<br/>observes Live&lt;T&gt; / LiveCollection&lt;T&gt;"]
    subgraph Store["Store (@MainActor)"]
        CacheStep["Cache step<br/>CachePolicy · in-flight dedupe"]
        ResourceCache["ResourceCache<br/>[ResourceKey: Entry]"]
        RequestCache["RequestCache<br/>[RequestKey: CachedDocument]"]
    end
    subgraph Chain["Handler chain (off the main actor)"]
        Bearer["BearerTokenHandler"] --> Logging["LoggingHandler"] --> URLSession["URLSessionHandler"]
    end
    Server["JSON:API server"]

    View -->|"find / query / save / delete"| CacheStep
    CacheStep -->|"RawRequest"| Bearer
    URLSession -->|"HTTP"| Server
    Server -.->|"RawResponse → JSONAPIDocument"| CacheStep
    CacheStep -.->|"upsert"| ResourceCache
    CacheStep -.->|"keys, links, meta"| RequestCache
    ResourceCache -.->|"Observation"| View
```

Solid arrows are calls; dashed arrows are data flowing back. Everything inside the store runs on the main actor; the handler chain and decoding run off it.

**Data flow of `store.find(Person.self, id: "42")`**

1. The store builds a `Request<JSONAPIDocument>` (`GET /people/42`, `op: .find`, `records: [person/42]`) and derives its `RequestKey` from the URL.
2. Cache step (inside the store, before any handler runs): if a `CachedDocument` exists for the key and the policy says `.fresh`, return the cached `Live<Person>` immediately. If `.stale`, return it and start a background refetch. If `.expired` or absent, or `reload` was requested, fetch and wait. A second caller with the same key while a fetch is in flight awaits the same task.
3. The handler chain runs off the main actor: `BearerTokenHandler` adds the header, `URLSessionHandler` performs the request and returns `RawResponse(status, headers, data)`.
4. Still off the main actor, the codec decodes `data` into a `JSONAPIDocument` (primary data, `included`, `links`, `meta`, `errors`) and decodes the primary resource objects into `Person` values, since the request's type is known. HTTP 4xx/5xx becomes `IonError.http`; a primary object that fails to decode fails the request with `IonError.decoding`.
5. One hop to the main actor: every resource object in `data` and `included` is upserted into the `ResourceCache` by `ResourceKey` as a raw `ResourceObject`; where a typed `Live<T>` already exists for the key it is re-decoded and its `value` updated. Primary objects get their `Live<Person>` now; included objects (`Tag`, `Group`) stay raw until the first typed access (`peek`, `resolve`, `find`), because the store cannot know their Swift type from the wire string alone. The document is stored under its `RequestKey` as a list of `ResourceKey`s plus `links` and `meta`.
6. The store returns the `Live<Person>` for `person/42`. Any view already showing that instance re-renders through Observation.

Writes follow the same path with two extras: before the request the draft's changes are serialized into the body, and after a success the response resource is upserted (so the live instance shows the server's version) and every cached query of the same type is invalidated, which reloads any `LiveCollection<T>` currently alive (see the invalidation rules under Cache). A response that arrives for a request started before the key's last mutation does not overwrite that key.

## Defining resources

A resource is a flat `Codable` struct that conforms to `Resource`; the struct's stored properties are the JSON:API `attributes`, properties typed `ToOne` / `ToMany` are the `relationships`, and `id` is the resource id. There is no schema object to register: the Swift type is the schema.

`swift
public protocol Resource: Codable, Sendable, Equatable {
    /// JSON:API `type`, e.g. "person"
    static var resourceType: String { get }
    /// Collection path relative to the store's base URL. Default: resourceType + "s".
    static var collectionPath: String { get }
    /// Server-assigned id. A new draft carries a client-local placeholder ("local:<uuid>") that is never sent.
    var id: String { get set }
}

struct Person: Resource {
    static let resourceType = "person"
    static let collectionPath = "people"

    var id: String
    var name: String
    var birthday: Date?
    var notes: String = ""
    var tags: ToMany<Tag> = .unloaded     // relationship: ids only in v1
    var group: ToOne<Group> = .unloaded

    // derived values are plain computed properties
    var initials: String { name.split(separator: " ").compactMap(\.first).map(String.init).joined() }
}
`

`ToOne<T>` and `ToMany<T>` are small `Codable` enums. `ToOne`: `.unloaded` (key absent from the payload), `.null` (`"data": null`), `.id("7")`. `ToMany`: `.unloaded` (key absent), `.ids(["7", "9"])` (`"data": []` when empty). Each decodes from a JSON:API relationship object and encodes back to one; encoding `.unloaded` omits the key entirely; `links` and `meta` on a relationship are ignored in v1. For form bindings they expose `ToOne.id: String?` (setting `nil` gives `.null`) and `ToMany.ids: [String]` as get/set properties, so a `Picker` binds to `$draft.value.group.id`. They carry `T` only so that `store.peek(person.value.group)` can return `Live<Group>?` without a cast.

**How the codec maps a struct to the wire format**

| Wire | Struct | Rule |
| --- | --- | --- |
| `type` | `Person.resourceType` | Checked on decode; mismatch is `IonError.decoding` |
| `id` | `id` | Always a `String`; a placeholder `local:…` id is omitted on POST and rejected anywhere else (`IonError.invalidDraft`) |
| `attributes.*` | every other stored property | Decoded by merging `id` and `attributes` into one JSON object and running `JSONDecoder`; keys are used as-is (snake_case servers set a `keyDecodingStrategy` on the store); dates parse ISO 8601 with or without fractional seconds |
| `relationships.*` | `ToOne` / `ToMany` properties | Decode: the keys of the wire `relationships` object are merged into the same JSON object as `{"data": …}` values. Encode: the codec runs a `JSONEncoder` whose `userInfo` carries a key collector; `ToOne`/`ToMany.encode(to:)` record their coding path there, and the codec moves exactly those keys into `relationships`. No static key list; custom `CodingKeys` keep working |
| `links`, `meta` on the resource | not mapped | Kept on the raw `ResourceObject` the cache holds, reachable as `Live<T>.raw` for debugging |

The merge-then-decode approach costs one dictionary rebuild per resource and keeps `Codable` synthesis, custom `CodingKeys`, defaults and optionals all working. It is the single most important simplification in IonKit: no property wrappers for attributes, no macros, no reflection, no registry of types.

**Identity.** `ResourceKey(type: "person", id: "42")` identifies a resource in the cache. The Village server assigns ids, so a new resource has none until the server answers: `Draft(new:)` fills `id` with a client-local placeholder (`local:` + UUID) that the codec never sends, and the `Live<T>` for a new resource is created from the response, with the server's id. Nothing is ever rekeyed. A draft whose relationships reference a `local:` id cannot be saved (`IonError.invalidDraft`); save the related resource first.

**Dates.** `Date` attributes are encoded as ISO 8601 UTC with fractional seconds and decoded with a custom strategy that accepts both forms (`Date.ISO8601FormatStyle(includingFractionalSeconds:)`, available in swift-foundation on Linux). `JSONDecoder`'s plain `.iso8601` rejects `2026-10-15T10:00:00.123Z`, which a `timestamptz` round-trip can produce.

## Requests and the handler chain

A request is a plain `Sendable` value; the store's `find` / `query` / `save` / `delete` methods are builders that produce one, and app code can build its own for endpoints IonKit does not know.

`swift
public struct Request<Response: Decodable & Sendable>: Sendable {
    public var method: HTTPMethod          // .get .post .patch .delete
    public var path: String                // "people/42" or an absolute URL
    public var query: [URLQueryItem]
    public var headers: [String: String]
    public var body: Data?
    public var op: Operation               // .find .query .create .update .delete .custom
    public var records: [ResourceKey]      // primary resources of a mutation
    public var cache: CacheOptions         // key, reload, backgroundReload, types
}

public protocol RequestHandler: Sendable {
    func handle(_ request: RawRequest, next: @Sendable (RawRequest) async throws -> RawResponse) async throws -> RawResponse
}

public struct RawResponse: Sendable { public let status: Int; public let headers: [String: String]; public let data: Data }
`

`RawRequest` is the request after the store resolved `path` + `query` against its base URL, plus JSON:API headers (`Accept` / `Content-Type: application/vnd.api+json`; media-type parameters such as `ext` and `profile` in a response are accepted and ignored). Handlers form a chain, last one `URLSessionHandler`; each may short-circuit, retry, or alter the request. v1 ships `BearerTokenHandler(token: @Sendable () async -> String?)` and `LoggingHandler`. A `401` surfaces as `IonError.http(status: 401, …)` and the app logs the user out; there is no token-refresh hook in v1 (a refresh handler is v1.x only if a consumer needs it).

**Store builders (v1)**

| Call | Produces | Result |
| --- | --- | --- |
| `store.find(Person.self, id:, include: [], cache: .default)` | `GET people/42?include=…`, `op: .find` | `Live<Person>` |
| `store.peek(Person.self, id:)` | no request | `Live<Person>?` from the cache; decodes a raw included entry on first access |
| `store.query(Person.self, filter: ["name": "Ann"], sort: ["-updatedAt"], page: ["size": "50"], include: [], cache:)` | `GET people?filter[name]=…`, `op: .query` | `LiveCollection<Person>`; returns after the first page is loaded (at once from cache); one instance per `RequestKey` |
| `store.query(Person.self, path: "groups/3/members")` | GET on a custom path, `op: .query` | `LiveCollection<Person>` |
| `store.save(&draft)` | `POST people` or `PATCH people/42`, `op: .create` / `.update`, `records: [key]` | `Live<Person>`; on success the draft's `original` becomes its `value` |
| `store.delete(live)` | `DELETE people/42`, `op: .delete` | `Void`; `live.isDeleted = true` and the item leaves every collection at once |
| `store.resolve(person.value.tags)` | `GET tags/{id}` for each id not in the cache | `[Live<Tag>]`; `peek` first, then `find` the gaps |
| `store.query(Person.self, request:)` | any GET request app code built | `LiveCollection<Person>`, registered under the request's key |
| `store.request(customRequest)` | whatever was built | `Request<JSONAPIDocument>` goes through the cache step and is upserted like any other response; `Request<Other>` is decoded with the codec's `JSONDecoder` and touches no cache |
| `store.upsert(document)` | no request | upserts every resource of a document the app obtained itself (push payload, seed data); the seam `store.patch` builds on in v2 |

Query parameters are sorted before the `RequestKey` is derived so that `filter[a]&filter[b]` and `filter[b]&filter[a]` share a cache entry (the WarpDrive `sortQueryParams` rule).

**Pagination** follows JSON:API `links` only. `LiveCollection<T>` exposes `links` and `loadMore()`, which fetches `links.next` and appends its items; `reload()` refetches the first page and drops appended pages (refetching every loaded page is a v1.x refinement). Page size and strategy stay a server concern.

**Errors** are one enum, and store methods use typed throws (`async throws(IonError)`): `.transport(URLError)`; `.http(status: Int, errors: [ErrorObject])` for 4xx/5xx with a parsed JSON:API `errors` array when present (`isNotFound` is a helper for 404); `.notFound(ResourceKey)` only when a `find` response carries `"data": null`; `.decoding(ResourceKey?, Error)`; `.invalidDraft(String)`; `.cancelled`, mapped from `CancellationError` and `URLError.cancelled` so a view that disappears mid-fetch never shows an error. An empty body or HTTP 204 decodes to an empty document and upserts nothing. `ErrorObject` keeps every member the spec defines (`id`, `status`, `code`, `title`, `detail`, `source.pointer` / `parameter` / `header`, `meta`, `links`); `IonError.http` offers `errors(forAttribute: "name")` and `errors(forRelationship: "group")`, which match on `source.pointer` when the server sends one (the spec makes it optional) and return an empty array otherwise, so forms degrade to showing `title`/`detail`.

**JSON:API coverage.** IonKit targets JSON:API 1.1 as a client; the table says what v1 does with each part of the spec so that an unfamiliar server works without changes to the package.

| Spec feature | v1 | Later |
| --- | --- | --- |
| Top-level `data` (one, many, `null`), `included`, `links`, `meta`, `errors`, `jsonapi` | all parsed; `jsonapi` and unknown members kept as `JSONValue` on the document | — |
| Resource `links`, `meta`, attributes the struct does not declare | kept on `raw` | typed access (v2) |
| Links as a string or as `{ "href", "rel", "describedby", "title", "type", "hreflang", "meta" }` | both forms parse into `Links` | — |
| Relationship objects: `data`, `links`, `meta`; `data: null` / `[]` | `data` mapped to `ToOne`/`ToMany`; `links`/`meta` on `raw` | relationship endpoints (`/x/1/relationships/y`) through `store.request` only |
| `include`, `fields[type]`, `filter`, `sort`, `page[*]` | passed through as given; a `fields` response decodes only if the struct's omitted properties are optional | field-level merge for sparse fieldsets (v2) |
| Pagination `links.first` / `prev` / `next` / `last` | `loadMore()`, `reload()`; absent links mean a single page | refetch of every loaded page (v1.x) |
| Client-generated ids and `lid` (1.1) | not sent; ids are server-assigned | opt-in client ids if a server requires them |
| Error objects with every spec member | parsed; field mapping when `source.pointer` is present | — |
| `Cache-Control`, `Expires`, `Date` | honored by `DefaultCachePolicy` | `ETag` / `If-None-Match` and 304 (v1.x) |
| Key casing (camelCase, snake_case, dasherized) | camelCase by default; `keyDecodingStrategy` / `keyEncodingStrategy` on the store | — |
| Atomic operations extension, profiles | not supported | if a consumer needs them |

## Cache

The cache is two dictionaries owned by the store, both main-actor only, both in RAM: a resource cache (identity map) and a request cache. Nothing is evicted in v1; a Village graph of a few thousand people and notes fits comfortably in memory.

**Resource cache** — `[ResourceKey: Entry]`, where `Entry` holds the latest raw `ResourceObject`, an optional typed `Live<T>` (stored as `any AnyLiveResource`), `isDeleted` and a `mutationSequence`. Every response passes through `upsert(document:)`, including responses to POST, PATCH, DELETE and custom requests, so a resource seen anywhere is current everywhere. Upsert replaces the raw object; if a `Live<T>` exists it is re-decoded and `live.value` is assigned only when `Equatable` says it changed (`updatedAt` and `raw` are written in the same branch, so an unchanged resource fires no Observation). A raw entry is decoded on its first typed access and the `Live<T>` is kept in the entry, which guarantees one instance per key because the entry outlives every view. A DELETE keeps the entry as a tombstone with `isDeleted = true`: a later response that still lists the key revives the same instance instead of creating a second one, and collections skip tombstones when they materialize. `store.clear()` is the only thing that drops entries in v1.

**Request cache** — `[RequestKey: CachedDocument]` where `CachedDocument` holds `primary: [ResourceKey]`, `included: [ResourceKey]`, `links`, `meta`, `receivedAt`, `invalidatedAt`, and an optional `types: Set<String>`. It stores keys, not copies, so a cached collection always materializes from the current live instances. `RequestKey` = method + resolved URL with sorted query, or `cache.key` when set (required to cache a POST query).

**Policy.** `CachePolicy` is a protocol with one method, `state(of entry: CachedDocument, now: Date) -> CacheState`, returning `.fresh`, `.stale` or `.expired`. `DefaultCachePolicy(soft: 1 min, hard: 24 h)` is configurable per store and overridable per request; it returns `.expired` whenever `invalidatedAt > receivedAt`, the server's `Cache-Control: max-age` / `Expires` (relative to the response `Date`) has passed, or `receivedAt` is older than `hard`; `.stale` when older than `soft`; otherwise `.fresh`. `Cache-Control: no-store` keeps a document out of the request cache entirely (resources are still upserted); `Cache-Control: no-cache` expires it at once. `NoCachePolicy` (every entry `.expired`) exists for tests. `CacheOptions.reload` and `CacheOptions.backgroundReload` are shorthands for the two flags. The cache step consults only the policy result, in this order on a GET:

1. `cache.reload == true` → fetch and wait.
2. no entry, or `.expired` → fetch and wait.
3. `.stale` or `cache.backgroundReload == true` → return cached, fetch in the background, upsert when done.
4. `.fresh` → return cached.

**In-flight deduplication and ordering.** `[RequestKey: Task<JSONAPIDocument, any Error>]`, keyed on the wire document so one map serves every `T`; a second caller awaits the existing task and decodes its own type; the entry is removed in a `defer`, so a failed fetch never pins a dead task. Mutations are never deduplicated. Each resource entry carries a `mutationSequence`, incremented when a `save` or `delete` for that key succeeds; a response from a request that started before the key's current sequence does not overwrite that entry (it still updates the request cache), which stops a slow background refetch from reverting a newer PATCH.

**Invalidation.** After a successful mutation the store applies the rules below. `store.invalidate(type:)` and `store.invalidate(key:)` expose the same for app code (after a push notification, say); `store.clear()` drops everything, for logout.

| Operation succeeded | Resource cache | Request cache | Alive collections of that type |
| --- | --- | --- | --- |
| `.create` | new entry + `Live<T>` from the response | every `.query` entry whose `types` contains the type: `invalidatedAt = now` | `reload()` if `autoRefresh` (the default) |
| `.update` | upsert the response, bump `mutationSequence` | same (membership and order may have changed) | `reload()` if `autoRefresh` |
| `.delete` | tombstone, bump `mutationSequence` | same | drop the item at once, then `reload()` if `autoRefresh` |
| custom `request` | upsert any resources in the response | nothing unless `cache.types` is set on the request | nothing |

The store finds alive collections through a weak registry `[RequestKey: WeakBox<any AnyLiveCollection>]`, purged on access; `query` returns the registered instance when it is still alive, so two screens showing the same query share one `LiveCollection`.

**Memory.** Entries, and therefore `Live` instances, are retained by the cache, not by views, so a view can hold a `Live<T>` strongly without worrying about ownership. `LiveCollection` holds the store weakly (not `unowned`: a background reload can outlive the store on logout or when a test ends, and must fail with `IonError.cancelled` rather than crash) and the store holds collections weakly, so there is no cycle and a collection dies with its last view. v2 adds a size cap with LRU eviction of request entries and of resources no view observes.

## Live instances, SwiftUI and concurrency

`Live<T>` is a read-only `@Observable` class holding the latest value of one resource; `LiveCollection<T>` holds an ordered list of `Live<T>` plus pagination state. Views observe them directly; there is no view model layer in the library.

`swift
@MainActor @Observable
public final class Live<T: Resource>: Identifiable {
    public let key: ResourceKey
    public private(set) var value: T
    public private(set) var raw: ResourceObject     // links, meta, attributes the struct does not model
    public private(set) var isDeleted = false
    public private(set) var updatedAt: Date
    nonisolated public var id: String { key.id }    // Identifiable's witness must be nonisolated
}

@MainActor @Observable
public final class LiveCollection<T: Resource> {
    public private(set) var items: [Live<T>]        // tombstoned items already filtered out
    public private(set) var links: Links            // next, prev, first, last, self
    public private(set) var meta: [String: JSONValue]
    public private(set) var state: LoadState        // .idle .loading .loaded .failed(IonError)
    public var autoRefresh = true
    public var hasMore: Bool                        // links.next != nil
    public func reload() async throws(IonError)
    public func loadMore() async throws(IonError)   // appends links.next
    weak var store: Store?                          // nil after the store died; loads then throw .cancelled
}
`

**Threading model.** `Store` (itself `@Observable`, so it can sit in the SwiftUI environment), both caches, `Live` and `LiveCollection` are `@MainActor`. The handler chain, `URLSession`, decoding into `JSONAPIDocument` and decoding of the primary `T` values run in `nonisolated` static async functions, which leave the main actor (the package does not enable `NonisolatedNonsendingByDefault`; when it does, mark them `@concurrent`); the store hops back once to upsert. Everything crossing the boundary is a `Sendable` value (`Request`, `RawResponse`, `JSONAPIDocument`, `T`). An `actor Store` was considered and rejected for v1: every read from SwiftUI would need an `await`, and Observation works most naturally on the main actor. `.task(id:)` cancels the `find` when a view disappears; the shared in-flight task keeps running for other awaiters and the cancelled caller gets `IonError.cancelled`.

**SwiftUI usage** (v1, no helpers beyond the two classes):

`swift
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
            catch .cancelled { }                 // the view went away; show nothing
            catch { self.error = error }         // typed throws: error is an IonError
        }
    }
}
`

The `Live<Person>` keeps updating after the task finishes: a later `query` that includes this person, a `save` from another screen, or a `reload()` all flow into the same instance. v1.x adds a `Fetch<T>` view that wraps the `task`/state boilerplate (`Fetch(Person.self, id: id) { live in … } loading: { … } failed: { … }`), equivalent to WarpDrive's `<Request>` component.

**Lists** bind `LiveCollection` directly: `ForEach(collection.items) { live in Row(person: live.value) }`. Swipe-to-delete calls `store.delete(live)`; the row leaves `items` immediately (tombstone) and the collection reloads in the background to pick up anything else that changed.

**Linux.** `Observation` ships with the Swift toolchain (not Apple-only), so `Live<T>` compiles and `withObservationTracking` works on Linux; only SwiftUI is absent. A Vapor service or a CLI can use the same store to talk to another JSON:API.

## Editing and saving

Edits never touch a `Live<T>`; they happen on a `Draft<T>`, a plain mutable struct that remembers what it started from, and reach the cache only through the server's response. This is WarpDrive's `checkout()` with the diff kept in the draft instead of in the cache.

`swift
public struct Draft<T: Resource>: Sendable {
    public var value: T                      // edit freely; bind TextFields to $draft.value.name
    public private(set) var original: T?     // nil for a new resource; reset by save
    public var isNew: Bool { original == nil }
    public var hasChanges: Bool              // true when the encoded diff is non-empty
    public mutating func revert()            // value = original

    public init(_ live: Live<T>)             // original = live.value; no store needed
    public init(new value: T)                // id replaced by a local placeholder
    public func isStale(against live: Live<T>) -> Bool   // live.value != original
}

var draft = Draft(person)                    // from a Live<Person>
var fresh = Draft(new: Person(id: "", name: ""))

draft.value.name = "Ann"
let saved: Live<Person> = try await store.save(&draft)   // PATCH people/42, body = changed fields only
`

**What `save` sends**

| Draft | Request | Body |
| --- | --- | --- |
| `isNew` | `POST {collectionPath}`, `op: .create`, `records: [key]` | full resource: `type`, `id`, all `attributes`, relationships that are not `.unloaded` |
| existing, `hasChanges` | `PATCH {collectionPath}/{id}`, `op: .update`, `records: [key]` | `type`, `id`, only attributes whose encoded JSON differs from `original`, only relationships that changed |
| existing, no changes | no request; returns the existing `Live<T>` | — |

The diff is computed by encoding `value` and `original` with the codec to `JSONValue` and comparing per key: an attribute whose encoded value differs is sent; an attribute present in `original` and absent in `value` (an optional set to `nil`) is sent as `null`; a relationship is sent when its encoded relationship object differs; a relationship that is `.unloaded` in `value` is never sent, and one that is `.unloaded` in `original` but set in `value` is sent, because the user set it (decided 2026-10-15). `hasChanges` means "this diff is non-empty", so a `Date` that differs only below the encoded precision never produces an empty PATCH. No per-field tracking in the struct, so user types stay plain.

**On success** the response document is upserted (the server's version wins, including server-set fields like `id` and `updatedAt`; a `204` to a PATCH means "accepted as sent", so the draft's value is upserted instead), queries for the type are invalidated as the Cache rules say, the draft passed `inout` gets `original = value` (so `hasChanges` is `false` and a double-tap sends nothing), and `save` returns the `Live<T>`. For a new resource the `Live<T>` is created only when the server confirms; before that nothing of the draft is visible elsewhere in the app. The same draft can keep being edited and saved again.

**On failure** nothing in the cache changes. `IonError.http(status: 422, errors:)` carries field-level messages via `errors(forAttribute:)`; `IonError.http(status: 409, ...)` or `412` is how a server signals a stale edit, and the app decides whether to reload the draft from the live value. IonKit does not send `If-Match` or compare versions in v1.

**Concurrent edits.** Two drafts of the same resource can exist in one app, or another device may save first; the last `save` wins and the live instance always shows the last server response. A form can call `draft.isStale(against: live)` before saving to warn the user. v2 can add an optional `version` attribute check if Village needs it.

**Delete.** `store.delete(live)` sends `DELETE`, then tombstones the entry, flags `live.isDeleted`, removes the item from every alive collection of that type and invalidates their cache entries. Views holding the instance should dismiss on `isDeleted`.

**What is deliberately missing in v1:** optimistic updates (show the edit before the server answers), rollback of a saved change, dirty-tracking on the live instance, and an offline write queue. Each would move local state into the cache, which is exactly the complexity the Draft model avoids.

## Relationships and includes

In v1 a relationship is a set of ids on the struct; resolving them is an explicit store call. Included resources ride along in every response and land in the cache like primary ones, so after `find(Person.self, id:, include: ["tags", "group"])` the lookups below are cache hits.

`swift
let person = try await store.find(Person.self, id: "42", include: ["tags"])
let tags: [Live<Tag>] = store.peek(person.value.tags)         // whatever is cached, in id order
let group: Live<Group>? = store.peek(person.value.group)
let allTags = try await store.resolve(person.value.tags)      // peek, then find the missing ones
`

- `peek(_:)` is synchronous and never hits the network; it returns only the instances present in the cache, decoding a raw included entry on first access.
- `resolve(_:)` fills gaps with one `find` per missing id in v1 (one query via `filter[id]` is a v1.x optimisation that depends on the server supporting it).
- Setting a relationship on a draft is assignment: `draft.value.tags.ids = ["7", "9"]`; `save` sends it as `relationships.tags.data`. Relationship `links` and the separate relationship endpoints are not used.
- There is no inverse maintenance: adding a tag to a person does not update the tag's `people` relationship locally; the next response that includes the tag does.

**v2: typed resolution.** `Live<T>` gains `related(\.tags) -> [Live<Tag>]` computed from the cache and observable, so a view can write `ForEach(person.related(\.tags))` and re-render when a tag arrives later. This is purely additive on top of the id-based model, which is why ids-only is the right v1.

## Platforms and dependencies

IonKit depends on nothing outside the Swift toolchain and Foundation, which is what makes the Linux target cheap.

| Concern | Choice |
| --- | --- |
| Swift | Swift 6.2 toolchain (Xcode 26), Swift 6 language mode, strict concurrency; `swift-tools-version: 6.2` |
| Apple platforms | `.macOS(.v15)`, `.iOS(.v18)`, built with Xcode 26; visionOS/tvOS/watchOS added to the manifest when someone needs them (no code change expected) |
| Linux | Swift 6.2+ with `FoundationNetworking` for `URLSession` (`#if canImport(FoundationNetworking)`), `Observation` from the toolchain; CI runs the test suite in the `swift:6.2` Docker image |
| Networking | `URLSession` only; no background sessions, no `URLSessionWebSocketTask` in v1 |
| JSON | `JSONDecoder` / `JSONEncoder`; a custom ISO 8601 date strategy that accepts fractional seconds; a `JSONValue` enum for untyped `meta`, `attributes` passthrough, the codec's merge step and the diff |
| Reactivity | `Observation` (`@Observable`, `withObservationTracking`); no Combine, so it compiles on Linux |
| Logging | `os.Logger` behind `#if canImport(os)`, `print` fallback on Linux, both behind `LoggingHandler` |
| Testing | `swift-testing`; `IonKitTesting` target with `MockHandler`: matches `method + path + sorted query` exactly, serves a FIFO queue of responses per key (repeating the last served one once drained), records every `RawRequest` in `requests`, throws `IonError.transport` for an unmatched key, and takes a `latency` for dedupe and cancellation tests; `respond(to: "GET people", with: [Person])` builds the JSON:API body through the codec, and `store.seed([Person])` upserts without a request |

Things known to differ on Linux and how the design avoids them: `URLSession` on Linux lacks some delegate features (not used), `Date` formatting differs slightly (IonKit only parses ISO 8601), and `@MainActor` exists but there is no run loop pumping it in a CLI — the test target runs store calls inside `await MainActor.run {}` where needed.

## Decisions and open questions

**Decided on 2026-10-15**

| Decision | Why |
| --- | --- |
| Any JSON:API 1.1 server is the target; Village is the first consumer and fixture source | Nothing app-specific in the package; spec-optional members stay optional in IonKit |
| Read through immutable `Live<T>`, edit through `Draft<T>` | Mirrors WarpDrive checkout; keeps local state out of the cache; structs stay plain |
| Minimum macOS 15 / iOS 18, Swift 6 strict concurrency | Observation, typed throws and modern concurrency without compatibility shims |
| Minimum toolchain is Swift 6.2 (Xcode 26); CI runs macOS with Xcode 26 and `swift:6.2` (decided 2026-10-15) | Typed throws on the async store API crash the 6.1 compiler at `-Onone` ([issue #1](https://github.com/winsmith/ion-kit/issues/1)); 6.2 compiles them |
| Relationships are ids + `peek`/`resolve` in v1 | Typed resolution is additive later; avoids a relationship graph in v1 |
| Store and caches are `@MainActor`, not an actor | Observation and SwiftUI read synchronously; network and decoding stay off-main anyway |
| Flat structs decoded via merge-then-`JSONDecoder`; relationship keys captured during encoding | Keeps `Codable` synthesis; no macros, property wrappers, reflection or type registry |
| Included resources stay raw until first typed access | The store cannot map a wire type string to a Swift type without a registry; lazy decoding needs none |
| Server-assigned ids; drafts carry a never-sent local placeholder | The Village server does not accept client ids; `Live<T>` is only ever created from a server response, so nothing is rekeyed |
| Wire keys are camelCase by default; `keyDecodingStrategy` / `keyEncodingStrategy` on the store | Village sends camelCase; other servers dasherize or snake_case |
| Default cache policy soft 1 min / hard 24 h, honoring `Cache-Control` / `Expires`, configurable per store and request | Village sets `Cache-Control`; a single-user app can keep data for a day and revalidate in the background |
| Field-level validation errors only when `source.pointer` is present | The spec makes `source` optional; forms fall back to `title` / `detail` |
| No token-refresh hook in v1; a 401 logs the user out | Email-code login issues long-lived tokens; refresh can be a handler later |
| Cache in RAM, no eviction, tombstones instead of removal, no persistence in v1 | Data volume is small; one instance per key must survive a delete; persistence is a v3 feature with a clear seam (`CacheSnapshot`) |
| Only `links`-based pagination; the server emits `links.next` | Offset/cursor strategies become the server's choice |
| No third-party dependencies | Linux build and long-term maintenance |
| A relationship set on a draft whose `original` had it `.unloaded` is sent; one that is `.unloaded` in the draft never is (added during v0.3, confirmed 2026-10-15) | Otherwise an edit to a resource fetched without `include` is dropped silently |

**Open questions** — each needs an answer before the milestone named

- **(v1.x)** Will Village need a `POST` query endpoint (search with a request body)? That decides how early `cache.key` for POST must be solid.
- Client-generated ids (no), key casing (camelCase), `links.next` (yes), expiry defaults (1 min / 24 h, configurable), `source.pointer` (optional, as in the spec), token refresh (none, log out), `Cache-Control` (yes) — all answered on 2026-10-15 and folded into the table above.

## Development milestones

Three milestones reach a usable v1.0; each one is independently testable without a network and ends with a gate Village can verify. Nothing after v1.0 is scheduled until Village ships on it.

```mermaid
flowchart LR
    v01["v0.1 Wire format ✅"] --> v02["v0.2 Reads ✅"] --> v03["v0.3 = v1.0 Writes ✅<br/>(Village gate open)"] --> v1x["v1.x Ergonomics"] --> v2["v2 Depth"] --> v3["v3 Persistence"]
    style v03 stroke-width:3px
```

Each band is a milestone in order; the gate on the right is what must be true before the next one starts.

**v0.1 — Wire format** (no store yet) — done 2026-10-15

- [x] `JSONAPIDocument`, `ResourceObject`, `RelationshipObject`, `ResourceIdentifier`, `ErrorObject`, `Links`, `JSONValue` — `Codable`, round-trip tested against fixtures.
- [x] `Resource` protocol, `ToOne` / `ToMany` with `id` / `ids` accessors, `ResourceKey`; the codec (`decode<T: Resource>(ResourceObject) -> T`, `encode(T) -> ResourceObject` with relationship-key capture, `diff(T, T) -> ResourceObject`); the ISO 8601 date strategy.
- [x] `Request`, `RawRequest`, `RawResponse`, `RequestHandler`, `URLSessionHandler`, `BearerTokenHandler`, `IonError`.
- [x] `IonKitTesting.MockHandler`; CI on macOS and Linux (fixtures are still `.synthetic.json`, [issue #3](https://github.com/winsmith/ion-kit/issues/3)).

**v0.2 — Reads** — done 2026-10-15

- [x] `Store` with `find`, `query`, `request`, `peek`, `resolve`; `Live<T>`, `LiveCollection<T>` with `LoadState`, `reload`, `loadMore`; the weak collection registry; key-casing strategies.
- [x] Resource cache with raw entries, lazy typed decode, upsert of primary + included, tombstones; request cache; `DefaultCachePolicy` with `Cache-Control` / `Expires` support; in-flight dedupe and `mutationSequence`; `invalidate(type:)`, `clear()`.
- [x] Gate: an integration test in `IonKitTests/StoreTests` reads a list and a detail through `MockHandler`; the Village read-only screens are the demo, not the gate.

**v0.3 = v1.0 — Writes** — package side done 2026-10-15; the Village gate is open ([issue #5](https://github.com/winsmith/ion-kit/issues/5))

- [x] `Draft<T>`, `store.save(&draft)` (POST / PATCH with diff), `store.delete`; server-assigned ids with local placeholders; `IonError.invalidDraft`.
- [x] The invalidation rules table, `LiveCollection.autoRefresh`, immediate local removal on delete; `IonError.http.errors(forAttribute:)`.
- [ ] Village creates, edits and deletes people, notes and tags through IonKit; README with the examples from this document (README done).
- [x] Typed throws on the whole async API, after raising the minimum toolchain to Swift 6.2.

**v1.x — Ergonomics** (as Village needs them; tracked in [issue #6](https://github.com/winsmith/ion-kit/issues/6)): `Fetch<T>` SwiftUI view over `LoadState`; `reload()` that refetches every loaded page; `ETag` / `If-None-Match` with 304 handling; retry with backoff for idempotent requests; `resolve` via one `filter[id]` query; POST queries with explicit keys if the open question above says yes.

**v2 — Depth**: `related(\.key)` observable relationship resolution; LRU eviction with a size cap; `store.patch(key, …)` for server push / websocket updates; optional `@Resource` macro to generate `resourceType` and `collectionPath`; sparse fieldsets with field-level merge; typed access to resource `links` and `meta`; opt-in client-generated ids for servers that require them.

**v3 — Persistence**: `CacheSnapshot` (encode the resource cache + request cache to a JSON or SQLite file, load on launch, serve as `.stale` until refreshed); optional offline write queue built on `Draft` values; conflict detection via a `version` attribute.

## Guidance for implementers (humans and agents)

This section is the contract for anyone picking up a task: where code goes, what a finished task looks like, and the rules that keep the library small.

**Package layout**

`
IonKit/
  Package.swift                 # swift-tools-version 6.2; targets IonKit, IonKitTesting, IonKitTests
  Sources/IonKit/
    Resource/      Resource.swift, ResourceKey.swift, Relationship.swift (ToOne, ToMany)
    WireFormat/    JSONAPIDocument.swift, ResourceObject.swift, ErrorObject.swift, JSONValue.swift, ResourceCodec.swift
    Requests/      Request.swift, RequestHandler.swift, URLSessionHandler.swift, BearerTokenHandler.swift, LoggingHandler.swift
    Cache/         ResourceCache.swift, RequestCache.swift, CachePolicy.swift
    Store/         Store.swift, Store+Find.swift, Store+Query.swift, Store+Save.swift, Store+Relationships.swift
    Reactive/      Live.swift, LiveCollection.swift, Draft.swift, LoadState.swift
    IonError.swift
  Sources/IonKitTesting/        MockHandler.swift, Fixtures.swift
  Tests/IonKitTests/            one file per source folder, fixtures under Resources/
  Examples/VillageSample/       the sample app, not part of the package build on Linux (not yet created)
  docs/ARCHITECTURE.md          this document
  AGENTS.md                     the agent guide: commands, conventions, definition of done; CLAUDE.md points to it
`

**Conventions**

- Public API lives in the files above; everything else is `internal`. Every public symbol has a doc comment with one usage line.
- `Sendable` on every value type that crosses the store boundary; `@MainActor` on every type that touches the caches. If the compiler asks for `@unchecked Sendable`, the design is wrong, not the annotation.
- Names follow this document: `Store`, `Live`, `LiveCollection`, `Draft`, `Request`, `RequestHandler`, `ResourceKey`, `RequestKey`, `IonError`. Do not introduce `Model`, `Record`, `Entity`, `Manager`.
- No new dependencies without a line in Decisions and open questions.
- Prefer deleting over abstracting: a feature not listed under the current milestone is a separate PR with a note in the milestone list, not a hook "for later".
- Keep the wire format honest: fixtures in `Tests/.../Resources` are real responses captured from the Village server, re-captured when the server changes. Until captured ones exist, hand-written fixtures are allowed if the file name ends in `.synthetic.json`; v0.1 needs at least `person-single.json` (with `included` tags, a `Date` attribute, a `null` to-one and an empty to-many), `people-collection.json` (with `links.next`), `error-422.json` and an empty 204 response.

**Definition of done for a task**

1. `swift build` and `swift test` pass on macOS (Xcode 26) and in the `swift:6.2` Linux container (`docker run --rm -v $PWD:/src -w /src swift:6.2 swift test`).
2. New behavior has a test against `MockHandler`, not the network.
3. Public API changes are reflected in this document (`docs/ARCHITECTURE.md`, the relevant section) and in the README example if it changes usage.
4. The milestone list above is updated: done items ticked, surprises added as open questions.

**Suggested task split for v0.1** (each is one PR an agent can take independently): (a) `JSONValue` + document types with fixture round-trips; (b) `Resource`, `ToOne`/`ToMany`, `ResourceKey`; (c) `ResourceCodec` decode/encode/diff; (d) `Request`/handlers/`URLSessionHandler`/`IonError`; (e) `MockHandler` + CI workflow. (b) and (c) depend on (a); (d) and (e) are independent.

**How to use this document when prompting an agent:** give it the section for the milestone, the Conventions block and the Definition of done; ask it to list the public API it will add before writing code, and to stop and ask when a decision in the table above would need to change.

## Current state of the code (v0.3, 2026-10-15)

This section is the reference for anyone, human or agent, depending on IonKit right now: what exists, what its
signatures are, and what to rely on. It describes the package as merged on `main` on 2026-10-15; update it in the
same pull request as any public API change.

**Status.** v0.1 (wire format), v0.2 (reads) and v0.3 (writes) are implemented in `Sources/IonKit` (about 2,600
lines) with `Sources/IonKitTesting` (about 200 lines) and 61 swift-testing tests that pass on macOS 15 (Xcode 26)
and in the `swift:6.2` container. Nothing on the v1.x / v2 / v3 lists exists yet. There is no
sample app and the fixtures are synthetic.

**Depending on it.**

```swift
// Package.swift
.package(url: "https://github.com/winsmith/ion-kit.git", branch: "main"),
…
.target(name: "App", dependencies: [.product(name: "IonKit", package: "ion-kit")]),
.testTarget(name: "AppTests", dependencies: [.product(name: "IonKitTesting", package: "ion-kit")]),
```

Platforms: macOS 15, iOS 18, Linux. Toolchain: Swift 6.2 (Xcode 26) or newer. Swift 6 language mode with strict concurrency; Foundation only.
No tags or releases exist yet; depend on `main` or a commit.

**Behaviors to rely on.**

- Every throwing method on `Store` and `LiveCollection` is `throws(IonError)`: `catch .cancelled { }` and a
  final `catch { error.status }` are exhaustive, and `error` is an `IonError` without a cast.
- `Store`, `Live`, `LiveCollection` are `@MainActor`; `Draft`, `Request`, every wire type and the codec are
  `Sendable` values. Call store methods from the main actor (SwiftUI `.task` already is).
- One `Live<T>` per `ResourceKey` per store, for as long as the store lives; identity (`===`) is stable, and a
  deleted resource keeps its instance with `isDeleted == true`.
- One `LiveCollection<T>` per request key while any view holds it; it dies with its last reference.
- GET responses are cached by `method + URL with sorted query`; mutations never are. Defaults: fresh for 1
  minute, stale-while-revalidate until 24 hours, server `Cache-Control` / `Expires` shorten that. Every
  response, cached or not, upserts its resources.
- After `save` or `delete`, cached queries of that resource type are expired and alive collections of it reload
  (`autoRefresh`). `delete` removes the item from collections before the reload.
- Resource structs: stored properties are attributes, `ToOne` / `ToMany` properties are relationships, `id` is
  the id. A missing relationship key decodes as `.unloaded`; a missing attribute key is a decoding error unless
  the property is optional (Swift's `Codable` synthesis ignores default values). Dates are ISO 8601, with or
  without fractional seconds. Key casing is configured once per store through `ResourceCodec`.

**Public API.** Signatures as they compile today, grouped by source folder; doc comments are in the code.

```swift
// Resource/
public protocol Resource: Codable, Sendable, Equatable {
    static var resourceType: String { get }
    static var collectionPath: String { get }          // default: resourceType + "s"
    var id: String { get set }
}
extension Resource {
    var resourceKey: ResourceKey { get }
    var hasLocalID: Bool { get }                       // id is a "local:" placeholder from Draft(new:)
    static var localIDPrefix: String { get }           // "local:"
    static func isLocalID(_ id: String) -> Bool
    static func makeLocalID() -> String
}

public struct ResourceKey: Hashable, Sendable, Codable, CustomStringConvertible {
    var type: String; var id: String
    init(type: String, id: String)
    init<T: Resource>(_ resourceType: T.Type, id: String)
}

public enum ToOne<T: Resource>: Hashable, Sendable, Codable {
    case unloaded, null, id(String)
    var id: String? { get set }                        // set nil → .null
    var isLoaded: Bool { get }
    var key: ResourceKey? { get }
    var relationshipObject: RelationshipObject? { get } // nil for .unloaded
    init(_ object: RelationshipObject?)
}
public enum ToMany<T: Resource>: Hashable, Sendable, Codable {
    case unloaded, ids([String])
    var ids: [String] { get set }                      // [] when unloaded; set always gives .ids
    var isLoaded: Bool { get }
    var keys: [ResourceKey] { get }
    var relationshipObject: RelationshipObject? { get }
    init(_ object: RelationshipObject?)
}
```

```swift
// WireFormat/
public enum JSONValue: Hashable, Sendable, Codable, ExpressibleBy{Nil,Boolean,Integer,Float,String,Array,Dictionary}Literal {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
    var stringValue: String?; var doubleValue: Double?; var intValue: Int?; var boolValue: Bool?
    var arrayValue: [JSONValue]?; var objectValue: [String: JSONValue]?; var isNull: Bool
    subscript(key: String) -> JSONValue?; subscript(index: Int) -> JSONValue?
    init(encoding value: some Encodable, encoder: JSONEncoder = JSONEncoder()) throws
    func decode<T: Decodable>(_ type: T.Type = T.self, decoder: JSONDecoder = JSONDecoder()) throws -> T
}

public struct Link: Hashable, Sendable, Codable {                 // string or link object on the wire
    var href: String; var rel, describedby, title, type, hreflang: String?; var meta: [String: JSONValue]?
    var url: URL? { get }
}
public struct Links: Hashable, Sendable, Codable {                // null members are dropped
    var all: [String: Link]
    subscript(name: String) -> Link? { get set }
    var selfLink, related, describedby, first, last, prev, next: Link? { get }
    var isEmpty: Bool { get }
}

public struct ResourceIdentifier: Hashable, Sendable, Codable {
    var type: String; var id: String; var lid: String?; var meta: [String: JSONValue]?
    init(_ key: ResourceKey); var key: ResourceKey { get }
}
public enum RelationshipData: Hashable, Sendable { case one(ResourceIdentifier?), many([ResourceIdentifier]); var identifiers: [ResourceIdentifier] { get } }
public struct RelationshipObject: Hashable, Sendable, Codable {   // data == nil: member absent
    var data: RelationshipData?; var links: Links?; var meta: [String: JSONValue]?
}
public struct ResourceObject: Hashable, Sendable, Codable {       // id == nil only on an outgoing create body
    var type: String; var id: String?; var lid: String?
    var attributes: [String: JSONValue]; var relationships: [String: RelationshipObject]
    var links: Links?; var meta: [String: JSONValue]?
    var key: ResourceKey? { get }
}

public struct ErrorSource: Hashable, Sendable, Codable {
    var pointer, parameter, header: String?
    var attribute: String? { get }                                // from "/data/attributes/<name>"
    var relationship: String? { get }                             // from "/data/relationships/<name>"
}
public struct ErrorObject: Hashable, Sendable, Codable {
    var id, status, code, title, detail: String?; var source: ErrorSource?; var links: Links?; var meta: [String: JSONValue]?
    var statusCode: Int? { get }
}

public enum PrimaryData: Hashable, Sendable { case one(ResourceObject?), many([ResourceObject]); var objects: [ResourceObject] { get } }
public struct JSONAPIDocument: Hashable, Sendable, Codable {
    var data: PrimaryData?                                        // nil: member absent; .one(nil): "data": null
    var included: [ResourceObject]; var links: Links?; var meta: [String: JSONValue]?
    var errors: [ErrorObject]?; var jsonapi: JSONValue?; var extensions: [String: JSONValue]
    init(one object: ResourceObject?, included: [ResourceObject] = [], links: Links? = nil, meta: [String: JSONValue]? = nil)
    init(many objects: [ResourceObject], included: [ResourceObject] = [], links: Links? = nil, meta: [String: JSONValue]? = nil)
    var allObjects: [ResourceObject] { get }; var isEmpty: Bool { get }
    static let mediaType: String                                  // "application/vnd.api+json"
    static func decode(_ data: Data) throws -> JSONAPIDocument    // empty body → empty document
    func encoded() throws -> Data
}

public struct ResourceCodec: Sendable {
    var keyDecodingStrategy: JSONDecoder.KeyDecodingStrategy; var keyEncodingStrategy: JSONEncoder.KeyEncodingStrategy
    init(keyDecodingStrategy: … = .useDefaultKeys, keyEncodingStrategy: … = .useDefaultKeys)
    static let `default`: ResourceCodec; static let snakeCase: ResourceCodec
    func decode<T: Resource>(_ object: ResourceObject, as type: T.Type = T.self) throws(IonError) -> T
    func encode<T: Resource>(_ value: T) throws(IonError) -> ResourceObject   // local id → id nil; .unloaded omitted
    func diff<T: Resource>(from original: T, to value: T) throws(IonError) -> ResourceObject
    static func isEmptyChange(_ object: ResourceObject) -> Bool
    func validateForSave(_ object: ResourceObject) throws(IonError)        // rejects "local:" relationship targets
    func makeDecoder() -> JSONDecoder; func makeEncoder() -> JSONEncoder
}
public enum CodecError: Error, Sendable { case typeMismatch(expected: String, found: String), missingID(type: String), notAnObject, localRelationship(String) }
public enum ISO8601 { static func parse(_ string: String) -> Date?; static func format(_ date: Date) -> String }
```

```swift
// Requests/
public enum HTTPMethod: String, Sendable { case get, post, patch, delete }
public enum Operation: Sendable { case find, query, create, update, delete, custom }
public struct CacheOptions: Sendable, Hashable {
    var key: String?; var reload: Bool; var backgroundReload: Bool; var types: Set<String>?
    init(key: String? = nil, reload: Bool = false, backgroundReload: Bool = false, types: Set<String>? = nil)
    static let `default`, reload, backgroundReload: CacheOptions
}
public struct Request<Response: Decodable & Sendable>: Sendable {
    var method: HTTPMethod; var path: String; var query: [URLQueryItem]; var headers: [String: String]
    var body: Data?; var op: Operation; var records: [ResourceKey]; var cache: CacheOptions
    init(method: HTTPMethod, path: String, query: [URLQueryItem] = [], headers: [String: String] = [:],
         body: Data? = nil, op: Operation = .custom, records: [ResourceKey] = [], cache: CacheOptions = .default)
    func decoding<Other: Decodable & Sendable>(_ type: Other.Type) -> Request<Other>
}
extension Request where Response == JSONAPIDocument {
    static func find<T: Resource>(_ type: T.Type, id: String, include: [String] = [], cache: CacheOptions = .default) -> Request
    static func query<T: Resource>(_ type: T.Type, path: String? = nil, filter: [String: String] = [:], sort: [String] = [],
                                   page: [String: String] = [:], include: [String] = [], query: [URLQueryItem] = [],
                                   cache: CacheOptions = .default) -> Request
}
public struct RequestKey: Hashable, Sendable { let value: String; init(_ value: String); init(method: HTTPMethod, url: URL) }
public struct RawRequest: Sendable, Hashable {
    var method: HTTPMethod; var url: URL; var headers: [String: String]; var body: Data?
    init<R>(_ request: Request<R>, baseURL: URL) throws(IonError)   // resolves path, sorts query, adds JSON:API headers
    var key: RequestKey { get }
}
public struct RawResponse: Sendable, Hashable {
    let status: Int; let headers: [String: String]; let data: Data
    func header(_ name: String) -> String?; var isSuccess: Bool { get }
}
public protocol RequestHandler: Sendable {
    func handle(_ request: RawRequest, next: @Sendable (RawRequest) async throws -> RawResponse) async throws -> RawResponse
}
public struct HandlerChain: Sendable { init(_ handlers: [any RequestHandler]); func perform(_ request: RawRequest) async throws -> RawResponse }
public struct URLSessionHandler: RequestHandler { init(session: URLSession = .shared) }
public struct BearerTokenHandler: RequestHandler { init(token: @escaping @Sendable () async -> String?) }
public struct LoggingHandler: RequestHandler {
    enum Level: Sendable { case summary, bodies }
    init(level: Level = .summary, sink: (@Sendable (String) -> Void)? = nil)
}
```

```swift
// IonError.swift
public enum IonError: Error, Sendable, CustomStringConvertible {
    case transport(URLError)
    case http(status: Int, errors: [ErrorObject])
    case notFound(ResourceKey)
    case decoding(ResourceKey?, any Error)
    case invalidDraft(String)
    case cancelled
    var isNotFound: Bool { get }; var status: Int? { get }; var errorObjects: [ErrorObject] { get }
    func errors(forAttribute name: String) -> [ErrorObject]
    func errors(forRelationship name: String) -> [ErrorObject]
    init(_ error: any Error)                                      // maps URLError / CancellationError / DecodingError
}
```

```swift
// Cache/
public enum CacheState: Sendable { case fresh, stale, expired }
public protocol CachePolicy: Sendable { func state(of entry: CachedDocument, now: Date) -> CacheState }
public struct DefaultCachePolicy: CachePolicy {
    var soft: TimeInterval; var hard: TimeInterval; var honorsServerHeaders: Bool
    init(soft: TimeInterval = 60, hard: TimeInterval = 86_400, honorsServerHeaders: Bool = true)
}
public struct NoCachePolicy: CachePolicy { init() }              // every entry .expired
public struct CachedDocument: Sendable {                          // keys, not copies
    var primary: [ResourceKey]; var included: [ResourceKey]; var isCollection: Bool
    var links: Links; var meta: [String: JSONValue]?; var op: Operation
    var receivedAt: Date; var invalidatedAt: Date?; var types: Set<String>?; var serverExpiry: Date?
}
```

```swift
// Store/   (all @MainActor)
@MainActor @Observable public final class Store {
    let baseURL: URL; let codec: ResourceCodec; var cachePolicy: any CachePolicy
    init(baseURL: URL, handlers: [any RequestHandler] = [URLSessionHandler()],
         codec: ResourceCodec = .default, cachePolicy: any CachePolicy = DefaultCachePolicy())

    // reads
    func find<T: Resource>(_ type: T.Type, id: String, include: [String] = [], cache: CacheOptions = .default) async throws(IonError) -> Live<T>
    func query<T: Resource>(_ type: T.Type, filter: [String: String] = [:], sort: [String] = [], page: [String: String] = [:],
                            include: [String] = [], cache: CacheOptions = .default) async throws(IonError) -> LiveCollection<T>
    func query<T: Resource>(_ type: T.Type, path: String, query: [URLQueryItem] = [], include: [String] = [],
                            cache: CacheOptions = .default) async throws(IonError) -> LiveCollection<T>
    func query<T: Resource>(_ type: T.Type, request: Request<JSONAPIDocument>) async throws(IonError) -> LiveCollection<T>
    func request(_ request: Request<JSONAPIDocument>) async throws(IonError) -> JSONAPIDocument   // cache step + upsert
    func request<Response: Decodable & Sendable>(_ request: Request<Response>) async throws(IonError) -> Response  // no cache
    func peek<T: Resource>(_ type: T.Type, id: String) -> Live<T>?
    func peek<T: Resource>(_ type: T.Type, key: ResourceKey) -> Live<T>?
    func peek<T: Resource>(_ relationship: ToOne<T>) -> Live<T>?
    func peek<T: Resource>(_ relationship: ToMany<T>) -> [Live<T>]
    func resolve<T: Resource>(_ relationship: ToOne<T>, cache: CacheOptions = .default) async throws(IonError) -> Live<T>?
    func resolve<T: Resource>(_ relationship: ToMany<T>, cache: CacheOptions = .default) async throws(IonError) -> [Live<T>]

    // writes
    @discardableResult func save<T: Resource>(_ draft: inout Draft<T>) async throws(IonError) -> Live<T>
    func delete<T: Resource>(_ live: Live<T>) async throws(IonError)

    // cache control
    func invalidate(type: String)                                 // expire queries of the type, reload alive collections
    func invalidate(key: ResourceKey)                             // expire documents whose primary data lists the key
    func clear()                                                  // logout
    func upsert(_ document: JSONAPIDocument)                      // push payloads, seeds; no request
    var cachedResourceCount: Int { get }
}
```

```swift
// Reactive/   (Live, LiveCollection are @MainActor @Observable)
public final class Live<T: Resource>: Identifiable {
    let key: ResourceKey
    private(set) var value: T
    private(set) var raw: ResourceObject                          // links, meta, unmodelled attributes
    private(set) var isDeleted: Bool
    private(set) var updatedAt: Date
    nonisolated var id: String { get }
}
public final class LiveCollection<T: Resource> {
    private(set) var items: [Live<T>]                             // tombstones filtered out
    private(set) var links: Links
    private(set) var meta: [String: JSONValue]
    private(set) var state: LoadState
    var autoRefresh: Bool                                         // default true
    let key: RequestKey
    var hasMore: Bool { get }
    func reload() async throws(IonError)                          // first page again; drops appended pages
    func loadMore() async throws(IonError)                        // appends links.next; no-op without one
}
public enum LoadState: Sendable { case idle, loading, loaded, failed(IonError); var isLoading, isLoaded: Bool; var error: IonError? }
public struct Draft<T: Resource>: Sendable {
    var value: T
    private(set) var original: T?                                 // nil for a new resource
    var isNew: Bool { get }; var hasChanges: Bool { get }
    @MainActor init(_ live: Live<T>)
    init(new value: T)                                            // id replaced by a local placeholder
    mutating func revert()
    @MainActor func isStale(against live: Live<T>) -> Bool
}
```

```swift
// IonKitTesting
public final class MockHandler: RequestHandler {
    static let defaultBaseURL: URL                                // https://mock.ionkit.test/
    init(baseURL: URL = defaultBaseURL, codec: ResourceCodec = .default, latency: Duration? = nil)
    var requests: [RawRequest] { get }; func requests(for key: String) -> [RawRequest]; func clearRequests()
    func respond(to key: String, with response: RawResponse)      // key: "GET people?include=tags" (query order free)
    func respond(to key: String, document: JSONAPIDocument, status: Int = 200, headers: [String: String] = [:])
    func respond<T: Resource>(to key: String, with value: T, included: [ResourceObject] = [], links: Links? = nil, meta: …, status: Int = 200, headers: …)
    func respond<T: Resource>(to key: String, with values: [T], included: [ResourceObject] = [], links: Links? = nil, meta: …, status: Int = 200, headers: …)
    func respond(to key: String, status: Int, errors: [ErrorObject], headers: … = [:])
    func respond(to key: String, status: Int, headers: … = [:])   // e.g. 204
    func respond(to key: String, data: Data, status: Int = 200, headers: … = [:])
    func key(for request: RawRequest) -> String
}
public enum Fixtures {
    static func object<T: Resource>(_ value: T, codec: ResourceCodec = .default) -> ResourceObject
    static func objects<T: Resource>(_ values: [T], codec: …) -> [ResourceObject]
    static func document<T: Resource>(_ value: T, included: [ResourceObject] = [], codec: …) -> JSONAPIDocument
    static func document<T: Resource>(_ values: [T], included: …, links: Links? = nil, codec: …) -> JSONAPIDocument
    static func data(named name: String, in bundle: Bundle) throws -> Data
}
extension Store { func seed<T: Resource>(_ values: [T]) }
```

**Not there yet** (so do not code against it): `Fetch<T>` view, `related(\.key)`, ETag / 304, retry handler,
token refresh, `filter[id]` resolve, POST queries, eviction, persistence, client-generated ids, sparse-fieldset
merging, relationship endpoints beyond `store.request`, the `@Resource` macro, typed resource `links` / `meta`.

## Implementation notes (2026-10-15)

What landed in v0.1–v0.3 (pull request #7) beyond or beside the sections above. Each item is also folded into its
section; this list is the changelog for the document.

- **Typed throws and the Swift 6.2 minimum.** v0.1–v0.3 first shipped with plain `throws` on the async store
  API because Swift 6.1 crashes at `-Onone` on typed throws from generic async functions whose result depends on
  `T`. Swift 6.2 compiles them (verified on CI), so the minimum toolchain was raised to 6.2 / Xcode 26 and
  `throws(IonError)` restored everywhere on 2026-10-15 ([issue #1](https://github.com/winsmith/ion-kit/issues/1)).
  `@concurrent` on the off-main functions turned out to erase their typed throws at the call site on 6.2, so they
  stay plain `nonisolated`.
- **`LiveCollection` holds its store weakly** (the document said `unowned`): a background reload scheduled by
  `invalidate(type:)` crashed with `swift_abortRetainUnowned` when the store died first, which CI caught on
  2026-10-15. Loads on an orphaned collection throw `IonError.cancelled`.
- **Relationship diff** sends a relationship the draft set even when `original` had it `.unloaded`
  (confirmed 2026-10-15, [issue #2](https://github.com/winsmith/ion-kit/issues/2)).
- **Small API additions:** `CacheOptions.reload` / `.backgroundReload`, `NoCachePolicy`,
  `store.upsert(_ document:)`, `store.query(T.self, request:)`, `LiveCollection.hasMore`,
  `IonError.errors(forRelationship:)`, `IonError.status` / `.errorObjects`, `JSONAPIDocument.decode(_:)` /
  `encoded()`, `ResourceCodec.snakeCase`, `ISO8601.parse` / `format`, `MockHandler(latency:)`,
  `MockHandler.requests(for:)`, `Fixtures` helpers and `store.seed` in `IonKitTesting`.
- **`Request<Response>`** is generic as designed, but the store builders produce `Request<JSONAPIDocument>`;
  there is no `Document<T>` wrapper type. `store.request` has two overloads (see the builders table).
- **Decoding missing relationship keys.** Synthesized `Codable` throws `keyNotFound` for a non-optional
  `ToOne` / `ToMany` property whose key the payload omitted, so the codec injects an empty relationship object for
  that key and retries, rethrowing the original error when the key turns out not to be a relationship. A plain
  attribute with a default value (`var notes: String = ""`) still needs the key on the wire: Swift's synthesis
  does not use defaults for missing keys.
- **Toolchain.** Verified on Swift 6.2 (Linux container) and Xcode 26 on macOS 15 through CI; the initial
  v0.1–v0.3 work was also verified on Swift 6.1.3 and Xcode 16.3 before the minimum moved. Swift 6.0 was never run.
- **Fixtures** are hand-written (`*.synthetic.json`) until captured from Village
  ([issue #3](https://github.com/winsmith/ion-kit/issues/3)). The Village sample app does not exist yet
  ([issue #5](https://github.com/winsmith/ion-kit/issues/5)).
