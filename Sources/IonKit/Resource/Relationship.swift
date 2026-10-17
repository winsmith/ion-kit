import Foundation
import Synchronization

/// A to-one relationship as ids only: absent from the payload, explicitly null, or one id.
///
/// Usage: `Picker("Group", selection: $draft.value.group.id) { … }`
public enum ToOne<T: Resource>: Hashable, Sendable {
    /// The relationship key was absent from the payload (or never loaded).
    case unloaded
    /// `"data": null`
    case null
    /// `"data": { "type": …, "id": … }`
    case id(String)

    /// The related id, or nil. Setting nil gives `.null`.
    public var id: String? {
        get {
            if case .id(let id) = self { return id }
            return nil
        }
        set { self = newValue.map { .id($0) } ?? .null }
    }

    /// True when the payload carried the relationship (as null or as an id).
    public var isLoaded: Bool {
        if case .unloaded = self { return false }
        return true
    }

    /// The cache key of the related resource, when there is one.
    public var key: ResourceKey? { id.map { ResourceKey(type: T.resourceType, id: $0) } }

    /// The relationship object this value encodes to; nil for `.unloaded`.
    public var relationshipObject: RelationshipObject? {
        switch self {
        case .unloaded: nil
        case .null: RelationshipObject(data: .one(nil))
        case .id(let id): RelationshipObject(data: .one(ResourceIdentifier(type: T.resourceType, id: id)))
        }
    }

    /// Builds a value from a decoded relationship object.
    public init(_ object: RelationshipObject?) {
        switch object?.data {
        case .none: self = .unloaded
        case .one(nil): self = .null
        case .one(let identifier?): self = .id(identifier.id)
        case .many(let identifiers): self = identifiers.first.map { .id($0.id) } ?? .null
        }
    }
}

/// A to-many relationship as ids only: absent from the payload or a list of ids (empty when `"data": []`).
///
/// Usage: `draft.value.tags.ids = ["7", "9"]`
public enum ToMany<T: Resource>: Hashable, Sendable {
    /// The relationship key was absent from the payload (or never loaded).
    case unloaded
    /// `"data": [ … ]`
    case ids([String])

    /// The related ids; empty when unloaded. Setting always gives `.ids`.
    public var ids: [String] {
        get {
            if case .ids(let ids) = self { return ids }
            return []
        }
        set { self = .ids(newValue) }
    }

    /// True when the payload carried the relationship.
    public var isLoaded: Bool {
        if case .unloaded = self { return false }
        return true
    }

    /// The cache keys of the related resources, in id order.
    public var keys: [ResourceKey] { ids.map { ResourceKey(type: T.resourceType, id: $0) } }

    /// The relationship object this value encodes to; nil for `.unloaded`.
    public var relationshipObject: RelationshipObject? {
        switch self {
        case .unloaded: nil
        case .ids(let ids): RelationshipObject(data: .many(ids.map { ResourceIdentifier(type: T.resourceType, id: $0) }))
        }
    }

    /// Builds a value from a decoded relationship object.
    public init(_ object: RelationshipObject?) {
        switch object?.data {
        case .none: self = .unloaded
        case .one(nil): self = .ids([])
        case .one(let identifier?): self = .ids([identifier.id])
        case .many(let identifiers): self = .ids(identifiers.map(\.id))
        }
    }
}

// MARK: - Codable

/// Collects the coding keys of relationship properties while a resource is encoded, so the codec can move
/// exactly those keys into `relationships` without a static key list. Sendable because `Encoder.userInfo`
/// holds `any Sendable`.
final class RelationshipKeyCollector: Sendable {
    private let recorded = Mutex<[[any CodingKey]]>([])

    var paths: [[any CodingKey]] {
        recorded.withLock { $0 }
    }

    func record(_ path: [any CodingKey]) {
        recorded.withLock { $0.append(path) }
    }
}

extension CodingUserInfoKey {
    static let relationshipKeyCollector = CodingUserInfoKey(rawValue: "ionkit.relationshipKeyCollector")!
}

extension ToOne: Codable {
    public init(from decoder: any Decoder) throws {
        self.init(try RelationshipObject(from: decoder))
    }

    public func encode(to encoder: any Encoder) throws {
        (encoder.userInfo[.relationshipKeyCollector] as? RelationshipKeyCollector)?.record(encoder.codingPath)
        try (relationshipObject ?? RelationshipObject()).encode(to: encoder)
    }
}

extension ToMany: Codable {
    public init(from decoder: any Decoder) throws {
        self.init(try RelationshipObject(from: decoder))
    }

    public func encode(to encoder: any Encoder) throws {
        (encoder.userInfo[.relationshipKeyCollector] as? RelationshipKeyCollector)?.record(encoder.codingPath)
        try (relationshipObject ?? RelationshipObject()).encode(to: encoder)
    }
}
