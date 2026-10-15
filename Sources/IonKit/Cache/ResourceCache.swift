import Foundation

/// The identity map: one entry per `ResourceKey` holding the latest raw object and, once typed access happened,
/// the single `Live<T>` for it. Entries are never removed except by `clear()`; a delete leaves a tombstone.
@MainActor
final class ResourceCache {
    struct Entry {
        var raw: ResourceObject
        var live: (any AnyLiveResource)?
        var isDeleted = false
        /// The store's mutation counter when this key was last mutated locally.
        var mutationSequence = 0
    }

    private(set) var entries: [ResourceKey: Entry] = [:]

    var count: Int { entries.count }

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
            var entry = Entry(raw: object)
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
        upsert(object, typed: Optional<NoResource>.none, codec: codec, startSequence: startSequence)
    }

    /// The live instance for a key, decoding the raw entry on first typed access. Nil when the key is unknown.
    func live<T: Resource>(for key: ResourceKey, as type: T.Type, codec: ResourceCodec) throws(IonError) -> Live<T>? {
        guard var entry = entries[key] else { return nil }
        if let existing = entry.live {
            guard let live = existing as? Live<T> else {
                throw .decoding(key, CodecError.typeMismatch(expected: T.resourceType, found: "\(Swift.type(of: existing))"))
            }
            return live
        }
        let value: T = try codec.decode(entry.raw)
        let live = Live<T>(key: key, value: value, raw: entry.raw)
        live.markDeleted(entry.isDeleted)
        entry.live = live
        entries[key] = entry
        return live
    }

    /// Marks a key deleted (keeping the entry so the same instance survives) and records the mutation.
    func tombstone(_ key: ResourceKey, sequence: Int) {
        guard var entry = entries[key] else { return }
        entry.isDeleted = true
        entry.mutationSequence = sequence
        entry.live?.markDeleted(true)
        entries[key] = entry
    }

    /// Records that a local mutation of the key succeeded.
    func bump(_ key: ResourceKey, sequence: Int) {
        entries[key]?.mutationSequence = sequence
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
