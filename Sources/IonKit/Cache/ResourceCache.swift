import Foundation

/// The identity map: one entry per `ResourceKey` holding the latest raw object and, once typed access happened,
/// the single `Live<T>` for it. A delete leaves a tombstone. Entries are removed by `clear()` and, when the store
/// has a `maxCachedResources` cap, by eviction of the least recently used ones no one else holds.
@MainActor
final class ResourceCache {
    struct Entry {
        var raw: ResourceObject
        /// The `Live<T>` once typed access happened, stored as `AnyObject` because `isKnownUniquelyReferenced`
        /// (see `isHeld`) does not accept a protocol existential. Use `live`.
        var instance: AnyObject?
        var isDeleted = false
        /// The store's mutation counter when this key was last mutated locally.
        var mutationSequence = 0
        /// The `clock` value when the entry was last written or read; 0 for an entry restored from a snapshot.
        var lastUsed = 0

        var live: (any AnyLiveResource)? {
            get { instance as? any AnyLiveResource }
            set { instance = newValue }
        }
    }

    private(set) var entries: [ResourceKey: Entry] = [:]
    /// Advances on every write or typed read of an entry, so `lastUsed` orders entries from least to most recently used.
    private(set) var clock = 0

    var count: Int { entries.count }

    private func tick() -> Int {
        clock += 1
        return clock
    }

    func entry(for key: ResourceKey) -> Entry? {
        entries[key]
    }

    /// Stores a raw object. When a `Live<T>` exists it is re-decoded; when `typed` is given that value is used
    /// instead. A response older than the key's last local mutation (`startSequence < mutationSequence`) does not
    /// overwrite the entry. Returns true when the entry was written.
    @discardableResult
    func upsert<T: Resource>(_ object: ResourceObject, typed: T? = nil, codec: ResourceCodec, startSequence: Int) -> Bool {
        guard let key = object.key else { return false }
        if var entry = entries[key] {
            guard entry.mutationSequence <= startSequence else { return false }
            entry.lastUsed = tick()
            entry.raw = object
            entry.isDeleted = false
            if let live = entry.live {
                if let typed, let live = live as? Live<T> {
                    live.apply(raw: object, value: typed)
                } else {
                    try? live.apply(raw: object, codec: codec)
                }
                live.markDeleted(false)
            } else if let typed {
                entry.live = Live<T>(key: key, value: typed, raw: object)
            }
            entries[key] = entry
        } else {
            var entry = Entry(raw: object, lastUsed: tick())
            if let typed {
                entry.live = Live<T>(key: key, value: typed, raw: object)
            }
            entries[key] = entry
        }
        return true
    }

    /// Stores an object without a typed value.
    @discardableResult
    func upsert(_ object: ResourceObject, codec: ResourceCodec, startSequence: Int) -> Bool {
        upsert(object, typed: NoResource?.none, codec: codec, startSequence: startSequence)
    }

    /// The live instance for a key, decoding the raw entry on first typed access. Nil when the key is unknown.
    func live<T: Resource>(for key: ResourceKey, as type: T.Type, codec: ResourceCodec) throws(IonError) -> Live<T>? {
        guard let entry = entries[key] else { return nil }
        if let existing = entry.live {
            guard let live = existing as? Live<T> else {
                throw IonError.decoding(key, CodecError.typeMismatch(expected: T.resourceType, found: "\(Swift.type(of: existing))"))
            }
            entries[key]?.lastUsed = tick()
            return live
        }
        let value: T = try codec.decode(entry.raw)
        let live = Live<T>(key: key, value: value, raw: entry.raw)
        live.markDeleted(entry.isDeleted)
        entries[key]?.live = live
        entries[key]?.lastUsed = tick()
        return live
    }

    /// Marks a key deleted (keeping the entry so the same instance survives) and records the mutation.
    func tombstone(_ key: ResourceKey, sequence: Int) {
        guard var entry = entries[key] else { return }
        entry.isDeleted = true
        entry.mutationSequence = sequence
        entry.lastUsed = tick()
        entry.live?.markDeleted(true)
        entries[key] = entry
    }

    /// Records that a local mutation of the key succeeded.
    func bump(_ key: ResourceKey, sequence: Int) {
        entries[key]?.mutationSequence = sequence
    }

    /// Marks the keys as used now, in order (a cached document served again).
    func touch(_ keys: [ResourceKey]) {
        for key in keys where entries[key] != nil {
            entries[key]?.lastUsed = tick()
        }
    }

    /// The keys of entries last used at or before `clock` value `threshold`, least recently used first; entries
    /// restored from a snapshot (all at 0) in key order.
    func keysByLastUsed(through threshold: Int) -> [ResourceKey] {
        entries
            .filter { $0.value.lastUsed <= threshold }
            .sorted { ($0.value.lastUsed, $0.key.type, $0.key.id) < ($1.value.lastUsed, $1.key.type, $1.key.id) }
            .map(\.key)
    }

    /// The local mutation sequence of a key; 0 when it was never mutated or is not cached.
    func mutationSequence(of key: ResourceKey) -> Int {
        entries[key]?.mutationSequence ?? 0
    }

    /// True when something outside the cache (a view, a collection's `items`, a local variable) holds the key's
    /// `Live`. Checked in place, so the check itself adds no reference.
    func isHeld(_ key: ResourceKey) -> Bool {
        guard entries[key]?.instance != nil else { return false }
        return !isKnownUniquelyReferenced(&entries[key]!.instance)
    }

    /// Drops an entry (eviction). Its `Live`, if any, is no longer reachable through the store.
    func remove(_ key: ResourceKey) {
        entries[key] = nil
    }

    /// Every entry as written to a snapshot: the raw object and the tombstone flag, sorted by key so the file is
    /// stable from one save to the next.
    func snapshotEntries() -> [CacheSnapshot.Entry] {
        entries
            .sorted { ($0.key.type, $0.key.id) < ($1.key.type, $1.key.id) }
            .map { CacheSnapshot.Entry(object: $0.value.raw, isDeleted: $0.value.isDeleted) }
    }

    /// Stores a raw object read from a snapshot unless the key already has an entry (anything in RAM is newer).
    /// The entry starts at mutation sequence 0, like everything in a new process. Returns true when it was stored.
    @discardableResult
    func restore(_ object: ResourceObject, isDeleted: Bool) -> Bool {
        guard let key = object.key, entries[key] == nil else { return false }
        entries[key] = Entry(raw: object, isDeleted: isDeleted)
        return true
    }

    func removeAll() {
        entries.removeAll()
    }
}

/// Stands in for "no typed primary" in the generic upsert and load paths.
struct NoResource: Resource {
    static let resourceType = ""
    var id: String
}
