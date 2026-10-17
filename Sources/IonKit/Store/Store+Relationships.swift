import Foundation

/// How `store.resolve(_ relationship: ToMany)` fetches the ids that are not in the cache.
///
/// Usage: `store.resolveStrategy = .batched()` once per store, or `store.resolve(person.tags, strategy: .batched(filter: "ids"))`
public enum ResolveStrategy: Sendable, Hashable {
    /// One `GET {collectionPath}/{id}` per missing id. Works against every server.
    case oneByOne
    /// One `GET {collectionPath}?filter[<filter>]=<id>,<id>,…` per `batchSize` missing ids (JSON:API's recommended
    /// filter form), then one `find` for any id the query did not return. A server that ignores the filter
    /// returns resources that were not asked for; from then on the call continues one by one.
    case batched(filter: String = "id", batchSize: Int = 50)
}

extension Store {
    /// The cached live instance a to-one relationship points at, without a request.
    public func peek<T: Resource>(_ relationship: ToOne<T>) -> Live<T>? {
        relationship.key.flatMap { peek(T.self, key: $0) }
    }

    /// The cached live instances of a to-many relationship, in id order, skipping ids not in the cache.
    public func peek<T: Resource>(_ relationship: ToMany<T>) -> [Live<T>] {
        relationship.keys.compactMap { peek(T.self, key: $0) }
    }

    /// The observable form of `peek`: the cached instances of a to-many relationship, in id order, skipping ids not
    /// in the cache, duplicate ids and deleted resources (as `LiveCollection.items` does). Reading it from a view
    /// body or `withObservationTracking` re-runs it when a resource of the type enters or leaves the cache or one of
    /// the returned instances is deleted. Never sends a request. Works with any relationship value, a draft's too.
    ///
    /// Usage: `ForEach(store.related(draft.value.tags)) { tag in Text(tag.value.name) }`
    public func related<T: Resource>(_ relationship: ToMany<T>) -> [Live<T>] {
        _ = resources.revision(for: T.resourceType).value   // tracked: keys of this type added or removed
        var seen = Set<ResourceKey>()
        var result: [Live<T>] = []
        for key in relationship.keys where seen.insert(key).inserted {
            if let live = peek(T.self, key: key), !live.isDeleted {
                result.append(live)
            }
        }
        return result
    }

    /// The observable form of `peek` for a to-one relationship: nil when the target is not cached or deleted.
    ///
    /// Usage: `if let group = store.related(draft.value.group) { Text(group.value.name) }`
    public func related<T: Resource>(_ relationship: ToOne<T>) -> Live<T>? {
        _ = resources.revision(for: T.resourceType).value   // tracked: keys of this type added or removed
        guard let live = peek(relationship), !live.isDeleted else { return nil }
        return live
    }

    /// The live instance of a to-one relationship, fetching it when it is not cached.
    public func resolve<T: Resource>(_ relationship: ToOne<T>, cache: CacheOptions = .default) async throws(IonError) -> Live<T>? {
        guard let key = relationship.key else { return nil }
        if !cache.reload, let live = peek(T.self, key: key) { return live }
        return try await find(T.self, id: key.id, cache: cache)
    }

    /// The live instances of a to-many relationship, in id order, fetching the ids that are not cached (all of
    /// them with `cache: .reload`) the way `strategy` says; default: the store's `resolveStrategy`.
    ///
    /// Usage: `let tags = try await store.resolve(person.value.tags)`
    public func resolve<T: Resource>(
        _ relationship: ToMany<T>, cache: CacheOptions = .default, strategy: ResolveStrategy? = nil
    ) async throws(IonError) -> [Live<T>] {
        let keys = relationship.keys
        var missing: [String] = []
        for key in keys where cache.reload || peek(T.self, key: key) == nil {
            if !missing.contains(key.id) { missing.append(key.id) }
        }
        var returned = Set<ResourceKey>()
        if case .batched(let filter, let batchSize) = strategy ?? resolveStrategy, !missing.isEmpty {
            let size = max(1, batchSize)
            var start = 0
            while start < missing.count {
                let batch = missing[start..<min(start + size, missing.count)].sorted()
                start += size
                let request = Request<JSONAPIDocument>.query(T.self, filter: [filter: batch.joined(separator: ",")], cache: cache)
                let document = try await load(request, as: T.self)
                let wanted = Set(batch.map { ResourceKey(T.self, id: $0) })
                guard document.primary.allSatisfy(wanted.contains) else { break }   // the server ignored the filter
                returned.formUnion(document.primary)
            }
        }
        var result: [Live<T>] = []
        for key in keys {
            // A batch's resources can be evicted by a later response when the store has a small cap; fetch those again.
            if returned.contains(key), resources.entry(for: key) != nil {
                let live = try liveResource(for: key, as: T.self)
                result.append(live)
            } else if !cache.reload, let live = peek(T.self, key: key) {
                result.append(live)
            } else {
                let live = try await find(T.self, id: key.id, cache: cache)
                result.append(live)
            }
        }
        return result
    }
}
