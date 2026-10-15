import Foundation

/// Identifies one resource: its JSON:API `type` and `id`.
///
/// Usage: `ResourceKey(type: "person", id: "42")`
public struct ResourceKey: Hashable, Sendable, CustomStringConvertible, Codable {
    public var type: String
    public var id: String

    public init(type: String, id: String) {
        self.type = type
        self.id = id
    }

    public init<T: Resource>(_ resourceType: T.Type, id: String) {
        self.init(type: T.resourceType, id: id)
    }

    public var description: String { "\(type)/\(id)" }
}

/// A JSON:API resource identifier object as it appears in relationship data.
public struct ResourceIdentifier: Hashable, Sendable, Codable {
    public var type: String
    public var id: String
    public var lid: String?
    public var meta: [String: JSONValue]?

    public init(type: String, id: String, lid: String? = nil, meta: [String: JSONValue]? = nil) {
        self.type = type
        self.id = id
        self.lid = lid
        self.meta = meta
    }

    public init(_ key: ResourceKey) {
        self.init(type: key.type, id: key.id)
    }

    public var key: ResourceKey { ResourceKey(type: type, id: id) }
}

/// The `data` member of a relationship object: one identifier (possibly null) or a list.
public enum RelationshipData: Hashable, Sendable {
    case one(ResourceIdentifier?)
    case many([ResourceIdentifier])

    /// Every identifier the relationship points at.
    public var identifiers: [ResourceIdentifier] {
        switch self {
        case .one(let identifier): identifier.map { [$0] } ?? []
        case .many(let identifiers): identifiers
        }
    }
}

/// A JSON:API relationship object. `data == nil` means the member was absent on the wire.
///
/// Usage: `object.relationships["tags"]?.data?.identifiers`
public struct RelationshipObject: Hashable, Sendable {
    public var data: RelationshipData?
    public var links: Links?
    public var meta: [String: JSONValue]?

    public init(data: RelationshipData? = nil, links: Links? = nil, meta: [String: JSONValue]? = nil) {
        self.data = data
        self.links = links
        self.meta = meta
    }
}

extension RelationshipObject: Codable {
    private enum CodingKeys: String, CodingKey {
        case data, links, meta
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var data: RelationshipData?
        if container.contains(.data) {
            if try container.decodeNil(forKey: .data) {
                data = .one(nil)
            } else if let many = try? container.decode([ResourceIdentifier].self, forKey: .data) {
                data = .many(many)
            } else {
                data = .one(try container.decode(ResourceIdentifier.self, forKey: .data))
            }
        }
        self.init(
            data: data,
            links: try container.decodeIfPresent(Links.self, forKey: .links),
            meta: try container.decodeIfPresent([String: JSONValue].self, forKey: .meta)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch data {
        case .none: break
        case .one(nil): try container.encodeNil(forKey: .data)
        case .one(let identifier?): try container.encode(identifier, forKey: .data)
        case .many(let identifiers): try container.encode(identifiers, forKey: .data)
        }
        try container.encodeIfPresent(links, forKey: .links)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

/// A JSON:API resource object exactly as it travels on the wire.
///
/// `id` is nil only on an outgoing create body; every object a server sends has one.
/// Usage: `live.raw.attributes["legacyField"]`
public struct ResourceObject: Hashable, Sendable {
    public var type: String
    public var id: String?
    public var lid: String?
    public var attributes: [String: JSONValue]
    public var relationships: [String: RelationshipObject]
    public var links: Links?
    public var meta: [String: JSONValue]?

    public init(
        type: String, id: String?, lid: String? = nil,
        attributes: [String: JSONValue] = [:], relationships: [String: RelationshipObject] = [:],
        links: Links? = nil, meta: [String: JSONValue]? = nil
    ) {
        self.type = type
        self.id = id
        self.lid = lid
        self.attributes = attributes
        self.relationships = relationships
        self.links = links
        self.meta = meta
    }

    /// The cache key, when the object carries an id.
    public var key: ResourceKey? {
        id.map { ResourceKey(type: type, id: $0) }
    }
}

extension ResourceObject: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, id, lid, attributes, relationships, links, meta
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            type: try container.decode(String.self, forKey: .type),
            id: try container.decodeIfPresent(String.self, forKey: .id),
            lid: try container.decodeIfPresent(String.self, forKey: .lid),
            attributes: try container.decodeIfPresent([String: JSONValue].self, forKey: .attributes) ?? [:],
            relationships: try container.decodeIfPresent([String: RelationshipObject].self, forKey: .relationships) ?? [:],
            links: try container.decodeIfPresent(Links.self, forKey: .links),
            meta: try container.decodeIfPresent([String: JSONValue].self, forKey: .meta)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(lid, forKey: .lid)
        if !attributes.isEmpty { try container.encode(attributes, forKey: .attributes) }
        if !relationships.isEmpty { try container.encode(relationships, forKey: .relationships) }
        try container.encodeIfPresent(links, forKey: .links)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}
