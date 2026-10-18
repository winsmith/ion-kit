import Foundation

/// A mutable copy of a resource for editing. Edits never touch the `Live<T>`; they reach the cache only through
/// the server's response to `store.save(&draft)`.
///
/// Usage:
/// ```swift
/// var draft = Draft(person)            // from a Live<Person>
/// draft.value.name = "Ann"
/// let saved = try await store.save(&draft)
/// ```
public struct Draft<T: Resource>: Sendable {
    /// Edit freely; bind `TextField`s to `$draft.value.name`.
    public var value: T
    /// What the draft started from; nil for a new resource. Reset by a successful save.
    public private(set) var original: T?

    /// True until the first successful save of a resource created with `Draft(new:)`.
    public var isNew: Bool { original == nil }

    /// True when the encoded diff against `original` is non-empty (always true for a new resource).
    public var hasChanges: Bool {
        guard let original else { return true }
        guard let diff = try? ResourceCodec.default.diff(from: original, to: value) else { return value != original }
        return !ResourceCodec.isEmptyChange(diff)
    }

    /// Starts editing a live resource. Needs no store.
    @MainActor
    public init(_ live: Live<T>) {
        self.value = live.value
        self.original = live.value
    }

    /// Starts a new resource. Its `id` is replaced by a client-local placeholder that is never sent; the server
    /// assigns the real id on save.
    public init(new value: T) {
        var value = value
        value.id = T.makeLocalID()
        self.value = value
        self.original = nil
    }

    /// Discards edits: `value = original`. Does nothing for a new resource.
    public mutating func revert() {
        if let original { value = original }
    }

    /// True when the live instance changed since the draft was made (another save or a refetch landed), in any
    /// field, including ones the draft did not touch. `conflicts(against:)` asks only about the edited fields.
    @MainActor
    public func isStale(against live: Live<T>) -> Bool {
        live.value != original
    }

    /// The attributes and relationships this draft changed that the live instance has also changed since the draft
    /// was made, to a different value: the edits a save would overwrite. Fields the draft did not touch never
    /// conflict, nor does a relationship the live value no longer carries (`.unloaded`). Empty for a new resource, and
    /// when a value does not encode (which the codec's own types never do; `isStale` still answers then).
    ///
    /// Usage: `if !draft.conflicts(against: live).isEmpty { askBeforeOverwriting() }`
    @MainActor
    public func conflicts(against live: Live<T>) -> Set<String> {
        guard let original else { return [] }
        let codec = ResourceCodec.default
        guard let changes = try? codec.diff(from: original, to: value), let before = try? codec.encode(original),
              let remote = try? codec.encode(live.value)
        else { return [] }
        var conflicts: Set<String> = []
        for (key, mine) in changes.attributes {
            let theirs = remote.attributes[key] ?? .null
            if theirs != (before.attributes[key] ?? .null), theirs != mine { conflicts.insert(key) }
        }
        for (key, mine) in changes.relationships {
            guard let theirs = remote.relationships[key] else { continue }
            if theirs != before.relationships[key], theirs != mine { conflicts.insert(key) }
        }
        return conflicts
    }

    /// Moves the draft onto the live instance's current value and keeps its edits: `original` becomes `live.value`,
    /// and `value` is that value with every attribute and relationship the draft changed set as the draft had it.
    /// Where the live value changed an edited field too, the draft's edit wins; check `conflicts(against:)` first to
    /// ask. Does nothing for a new resource, or when a value does not encode.
    ///
    /// Usage: `_ = try await store.find(Person.self, id: id, cache: .reload); draft.rebase(onto: live)`
    @MainActor
    public mutating func rebase(onto live: Live<T>) {
        guard let original else { return }
        let codec = ResourceCodec.default
        do throws(IonError) {
            let changes = try codec.diff(from: original, to: value)
            var rebased = try codec.encode(live.value)
            for (key, attribute) in changes.attributes {
                if attribute == .null { rebased.attributes.removeValue(forKey: key) } else { rebased.attributes[key] = attribute }
            }
            for (key, relationship) in changes.relationships {
                rebased.relationships[key] = relationship
            }
            value = try codec.decode(rebased, as: T.self)
            self.original = live.value
        } catch {
            return
        }
    }

    /// Records a successful save: `original = value`, with the server-assigned id for a new resource.
    mutating func markSaved(id: String) {
        value.id = id
        original = value
    }
}
