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

    init(key: ResourceKey, value: T, raw: ResourceObject, updatedAt: Date = Date()) {
        self.key = key
        self.value = value
        self.raw = raw
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

extension Live: CustomStringConvertible {
    nonisolated public var description: String { "Live<\(T.self)>(\(key))" }
}
