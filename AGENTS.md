# IonKit — guide for agents and contributors

A Swift package for talking to JSON:API 1.1 servers from SwiftUI: live-updating resource instances, drafts for
edits, an in-memory cache. The design document is the contract for every change:
https://claude.ai/artifact/RLz9GDSBMCbgVqRGQ8UJY3 ("IonKit Architecture Design"). Read the section for the
milestone you are working on, the Conventions block and the Definition of done before writing code.

## Commands

```sh
swift build
swift test
swift build -c release
docker run --rm -v $PWD:/src -w /src swift:6.1 swift test   # Linux, what CI runs
```

Tests use swift-testing and `IonKitTesting.MockHandler`; nothing touches the network.

## Layout

```
Sources/IonKit/
  Resource/      Resource, ResourceKey, ToOne / ToMany
  WireFormat/    JSONValue, JSONAPIDocument, ResourceObject, ErrorObject, Links, ResourceCodec
  Requests/      Request, RawRequest, RawResponse, RequestHandler, URLSessionHandler, BearerTokenHandler, LoggingHandler
  Cache/         ResourceCache (identity map), RequestCache, CachePolicy
  Store/         Store, Store+Find, Store+Query, Store+Save, Store+Relationships
  Reactive/      Live, LiveCollection, Draft, LoadState
  IonError.swift
Sources/IonKitTesting/   MockHandler, Fixtures, Store.seed
Tests/IonKitTests/       one file per source folder; fixtures under Resources/ (*.synthetic.json until real
                         captures from the Village server replace them)
```

## Conventions

- Public API lives in the files above; everything else is internal. Every public symbol has a doc comment with
  one usage line.
- `Sendable` on every value that crosses the store boundary; `@MainActor` on every type that touches the caches.
  If the compiler asks for `@unchecked Sendable`, the design is wrong, not the annotation.
- Names follow the design document: Store, Live, LiveCollection, Draft, Request, RequestHandler, ResourceKey,
  RequestKey, IonError. Do not introduce Model, Record, Entity, Manager.
- No new dependencies without a line in the design document's decisions table.
- Prefer deleting over abstracting: a feature not in the current milestone is a separate PR, not a hook.

## Known toolchain issue: typed throws

The design calls for `async throws(IonError)` on store methods. Swift 6.1 (the toolchain in `swift:6.1` and
Xcode 16.3/16.4) crashes in IRGen at `-Onone` whenever a generic async function with typed throws returns a type
that depends on `T` (`Live<T>`, `LiveCollection<T>`, `[ResourceKey: T]`) and the caller uses the result. Release
builds are unaffected. Whether Swift 6.2 fixes it is not verified yet (the CI job for `swift:6.2` is
non-blocking until it is). Until the minimum toolchain is one that compiles it, async store and collection
methods use plain `throws` and are documented to throw `IonError` only; synchronous codec methods keep typed
throws. `catch IonError.cancelled` works everywhere. Once the toolchain allows it, restore `throws(IonError)` on
`find`, `query`, `resolve`, `save`, `delete`, `request`, `reload`, `loadMore` and the internal `load`/`fetch`
path. A minimal reproducer: a generic `func b<T: P>(_: T.Type) async throws(E) -> C<T>` called with
`let c = try await s.b(X.self); _ = c.v` crashes `swiftc -Onone` 6.1.3.

## Definition of done

- `swift build` and `swift test` pass on macOS and in the `swift:6.1` container.
- New behavior has a test against `MockHandler`, not the network.
- Public API changes are reflected in the design document and, if usage changes, in the README.
- The design document's milestone list is updated: done items ticked, surprises added as open questions.
