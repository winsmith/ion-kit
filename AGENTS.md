# IonKit — guide for agents and contributors

A Swift package for talking to JSON:API 1.1 servers from SwiftUI: live-updating resource instances, drafts for
edits, an in-memory cache. The design document [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) is the canonical
source of truth and the contract for every change. Read the section for the milestone you are working on, the
Conventions block and the Definition of done before writing code, and update the document in the same pull
request as the code.

## Commands

```sh
swift build
swift test
swift build -c release
docker run --rm -v $PWD:/src -w /src swift:6.2 swift test   # Linux, what CI runs
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

## Toolchain

Swift 6.2 (Xcode 26 on macOS, the `swift:6.2` image on Linux) is the minimum. Older toolchains crash in IRGen at
`-Onone` on the typed throws the store API uses (`async throws(IonError)` on generic functions returning
`Live<T>` / `LiveCollection<T>`); see issue #1 for the reproducer. Do not work around that by dropping typed
throws again.

## Definition of done

- `swift build` and `swift test` pass on macOS (Xcode 26) and in the `swift:6.2` container.
- New behavior has a test against `MockHandler`, not the network.
- Public API changes are reflected in `docs/ARCHITECTURE.md` and, if usage changes, in the README.
- The milestone list in `docs/ARCHITECTURE.md` is updated: done items ticked, surprises added as open questions
  and to its "Implementation notes" section.
