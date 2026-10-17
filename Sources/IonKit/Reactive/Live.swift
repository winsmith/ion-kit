import Foundation
import Observation

/// What the resource cache needs from a `Live<T>` without knowing `T`.
@MainActor
protocol AnyLiveResource: AnyObject {
    var key: ResourceKey { get }
    var isDeleted: Bool { get }
    /// Re-decodes `raw` and updates `value` when it changed. Throws when the raw object no longer decodes.
    func apply(raw: ResourceObject, codec: ResourceCodec) throws(IonError)
    func markDeleted(_ deleted: Bool)
}

/// The live, read-only instance of one resource. There is exactly one per `ResourceKey` in a store; every
/// response that touches the resource updates it, and SwiftUI views observe it directly.
///
/// Usage: `Text(person.value.name)` inside a view holding a `Live<Person>`.
@MainActor @Observable
public final class Live<T: Resource>: Identifiable, AnyLiveResource {
    /// The resource's type and id.
    public let key: ResourceKey
    /// The latest decoded value.
    public private(set) var value: T
    /// The latest wire object: links, meta and attributes the struct does not model.
    public private(set) var raw: ResourceObject
    /// True after a successful DELETE; the instance stays so that views can dismiss.
    public private(set) var isDeleted = false
    /// When `value` last changed.
    public private(set) var updatedAt: Date

    nonisolated public var id: String { key.id }

    /// The store whose cache holds this instance; weak, so an instance a view keeps does not keep a cleared-away
    /// store alive. Nil once the store is gone, and then `related` returns nothing.
    @ObservationIgnored private(set) weak var store: Store?

    init(key: ResourceKey, value: T, raw: ResourceObject, store: Store? = nil, updatedAt: Date = Date()) {
        self.key = key
        self.value = value
        self.raw = raw
        self.store = store
        self.updatedAt = updatedAt
    }

    func apply(raw: ResourceObject, codec: ResourceCodec) throws(IonError) {
        let decoded: T = try codec.decode(raw)
        apply(raw: raw, value: decoded)
    }

    /// Updates from an already decoded value; assigns only when the value changed so that an unchanged
    /// resource fires no observation.
    func apply(raw: ResourceObject, value newValue: T) {
        guard newValue != value || raw != self.raw else { return }
        value = newValue
        self.raw = raw
        updatedAt = Date()
    }

    func markDeleted(_ deleted: Bool) {
        if isDeleted != deleted { isDeleted = deleted }
    }
}

extension Live {
    /// The cached, not deleted instances a to-many relationship of this resource points at, in id order and
    /// without duplicates. Observable: a view calling it re-renders when the ids change, when one of the related
    /// resources arrives in the cache or leaves it, and when one is deleted. Never sends a request; call
    /// `store.resolve(_:)` to fetch the ones that are missing, and this updates when they land.
    ///
    /// Usage: `ForEach(person.related(\.tags)) { tag in Text(tag.value.name) }`
    public func related<R: Resource>(_ keyPath: KeyPath<T, ToMany<R>>) -> [Live<R>] {
        let relationship = value[keyPath: keyPath]
        return store?.related(relationship) ?? []
    }

    /// The cached, not deleted instance a to-one relationship of this resource points at; nil when it is not
    /// cached, deleted, `.null` or `.unloaded`. Observable like the to-many form; never sends a request.
    ///
    /// Usage: `if let group = person.related(\.group) { Text(group.value.name) }`
    public func related<R: Resource>(_ keyPath: KeyPath<T, ToOne<R>>) -> Live<R>? {
        let relationship = value[keyPath: keyPath]
        return store?.related(relationship)
    }
}

extension Live: CustomStringConvertible {
    nonisolated public var description: String { "Live<\(T.self)>(\(key))" }
}
