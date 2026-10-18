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
docker run --rm -v $PWD:/src -w /src swift:6.2 swift test   # Linux, the minimum; CI also runs swift:6.4
swiftlint                                                    # brew install swiftlint; config in .swiftlint.yml
docker run --rm -v $PWD:/src -w /src ghcr.io/realm/swiftlint:0.59.1 swiftlint   # the version CI runs
```

Run `swiftlint` locally before every push; the SwiftLint workflow fails on errors and annotates warnings. Fix
new warnings rather than adding them. Default rules stay on; multi-line collection literals end with a trailing
comma. Suppress a rule only at the declaration that needs it, with a reason after ` - `:
`// swiftlint:disable:next identifier_name - mirrors the "ok" key in the response`. Prefer splitting a function
over suppressing `cyclomatic_complexity`.

Tests use swift-testing and `IonKitTesting.MockHandler`; nothing touches the network.

## Layout

```
Sources/IonKit/
  Resource/      Resource, ResourceKey, ToOne / ToMany
  WireFormat/    JSONValue, JSONAPIDocument, ResourceObject, ErrorObject, Links, ResourceCodec
  Requests/      Request, RawRequest, RawResponse, RequestHandler, URLSessionHandler, BearerTokenHandler, LoggingHandler, RetryHandler
  Cache/         ResourceCache (identity map), RequestCache, CachePolicy, CacheSnapshot (the snapshot file format)
  Store/         Store, Store+Find, Store+Query, Store+Save, Store+Relationships, Store+Snapshot, Store+Eviction
  Reactive/      Live, LiveCollection, Draft, LoadState
  SwiftUI/       Fetch, FetchFailureView (behind `#if canImport(SwiftUI)`; not built on Linux, so CI's macOS job is
                 the only one that compiles it)
  IonError.swift
Sources/IonKitTesting/   MockHandler, Fixtures, Store.seed
Tests/IonKitTests/       one file per source folder; fixtures under Resources/ (*.synthetic.json until real
                         captures from the vllage server replace them)
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

## Toolchain and typed throws

The minimum toolchain is Swift 6.2 (Xcode 26; `swift-tools-version: 6.2`). Swift 6.1 crashed in IRGen at `-Onone`
on generic async functions with typed throws, which kept the store API on plain `throws` until v1.5 (issue #1).
Every async method on `Store` and `LiveCollection` is now `async throws(IonError)`; keep it that way, and convert
`any Error` with `IonError(_:)` only where it enters: the handler chain, `Task.value`, `JSONEncoder` / `JSONDecoder`.
Inside a closure (a `Task { }`, SwiftUI's `.task`) Swift 6.2–6.4 do not infer a `do` block's error type: write
`do throws(IonError) { … } catch .cancelled { … }` there.

## Releasing

Releases are git tags on `main` that follow semantic versioning (`1.3.0`; the first two were tagged `1.1` and
`1.2`). A release pull request moves the "Current state of the code" heading and status in
`docs/ARCHITECTURE.md` to the new version, ticks its milestone and adds an "Implementation notes" section. Once it
is merged, the maintainer tags the merge commit (`git tag 1.3.0 <sha> && git push origin 1.3.0`). Consumers then
raise their `from:` requirement and re-resolve; vllage does that in its own pull request.

## Definition of done

- `swift build` and `swift test` pass on macOS (Xcode 26) and in the `swift:6.2` container.
- `swiftlint` reports no errors and no new warnings.
- New behavior has a test against `MockHandler`, not the network.
- Public API changes are reflected in `docs/ARCHITECTURE.md` and, if usage changes, in the README.
- The milestone list in `docs/ARCHITECTURE.md` is updated: done items ticked, surprises added as open questions
  and to its "Implementation notes" section.
