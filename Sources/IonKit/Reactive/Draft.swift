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

    /// True when the live instance changed since the draft was made (another save or a refetch landed).
    @MainActor
    public func isStale(against live: Live<T>) -> Bool {
        live.value != original
    }

    /// Records a successful save: `original = value`, with the server-assigned id for a new resource.
    mutating func markSaved(id: String) {
        value.id = id
        original = value
    }
}
