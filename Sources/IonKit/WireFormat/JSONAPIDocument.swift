import Foundation

/// The top-level `data` member: one resource (possibly null) or a list.
public enum PrimaryData: Hashable, Sendable {
    case one(ResourceObject?)
    case many([ResourceObject])

    /// Every resource object in the primary data, in document order.
    public var objects: [ResourceObject] {
        switch self {
        case .one(let object): object.map { [$0] } ?? []
        case .many(let objects): objects
        }
    }
}

/// A JSON:API document. Every top-level member is parsed; `jsonapi` and members the spec does not
/// define are kept as `JSONValue`.
///
/// Usage: `document.data?.objects.first?.key`
public struct JSONAPIDocument: Hashable, Sendable {
    public var data: PrimaryData?
    public var included: [ResourceObject]
    public var links: Links?
    public var meta: [String: JSONValue]?
    public var errors: [ErrorObject]?
    public var jsonapi: JSONValue?
    /// Top-level members the spec does not define, by name.
    public var extensions: [String: JSONValue]

    public init(
        data: PrimaryData? = nil, included: [ResourceObject] = [], links: Links? = nil,
        meta: [String: JSONValue]? = nil, errors: [ErrorObject]? = nil, jsonapi: JSONValue? = nil,
        extensions: [String: JSONValue] = [:]
    ) {
        self.data = data
        self.included = included
        self.links = links
        self.meta = meta
        self.errors = errors
        self.jsonapi = jsonapi
        self.extensions = extensions
    }

    /// A document whose primary data is one resource.
    public init(one object: ResourceObject?, included: [ResourceObject] = [], links: Links? = nil, meta: [String: JSONValue]? = nil) {
        self.init(data: .one(object), included: included, links: links, meta: meta)
    }

    /// A document whose primary data is a list.
    public init(many objects: [ResourceObject], included: [ResourceObject] = [], links: Links? = nil, meta: [String: JSONValue]? = nil) {
        self.init(data: .many(objects), included: included, links: links, meta: meta)
    }

    /// Every resource object in `data` and `included`.
    public var allObjects: [ResourceObject] {
        (data?.objects ?? []) + included
    }

    /// True when the document carries no data, no errors and no meta: what an empty body or HTTP 204 decodes to.
    public var isEmpty: Bool {
        data == nil && included.isEmpty && links == nil && meta == nil && errors == nil && jsonapi == nil && extensions.isEmpty
    }
}

extension JSONAPIDocument: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        var document = JSONAPIDocument()
        for key in container.allKeys {
            switch key.stringValue {
            case "data":
                if try container.decodeNil(forKey: key) {
                    document.data = .one(nil)
                } else if let many = try? container.decode([ResourceObject].self, forKey: key) {
                    document.data = .many(many)
                } else {
                    document.data = .one(try container.decode(ResourceObject.self, forKey: key))
                }
            case "included":
                document.included = try container.decodeIfPresent([ResourceObject].self, forKey: key) ?? []
            case "links":
                document.links = try container.decodeIfPresent(Links.self, forKey: key)
            case "meta":
                document.meta = try container.decodeIfPresent([String: JSONValue].self, forKey: key)
            case "errors":
                document.errors = try container.decodeIfPresent([ErrorObject].self, forKey: key)
            case "jsonapi":
                document.jsonapi = try container.decodeIfPresent(JSONValue.self, forKey: key)
            default:
                document.extensions[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
            }
        }
        self = document
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        switch data {
        case .none: break
        case .one(nil): try container.encodeNil(forKey: AnyCodingKey("data"))
        case .one(let object?): try container.encode(object, forKey: AnyCodingKey("data"))
        case .many(let objects): try container.encode(objects, forKey: AnyCodingKey("data"))
        }
        if !included.isEmpty { try container.encode(included, forKey: AnyCodingKey("included")) }
        try container.encodeIfPresent(links, forKey: AnyCodingKey("links"))
        try container.encodeIfPresent(meta, forKey: AnyCodingKey("meta"))
        try container.encodeIfPresent(errors, forKey: AnyCodingKey("errors"))
        try container.encodeIfPresent(jsonapi, forKey: AnyCodingKey("jsonapi"))
        for (name, value) in extensions.sorted(by: { $0.key < $1.key }) {
            try container.encode(value, forKey: AnyCodingKey(name))
        }
    }
}

extension JSONAPIDocument {
    /// The JSON:API media type sent in `Accept` and `Content-Type`.
    public static let mediaType = "application/vnd.api+json"

    /// Decodes a document from a response body. An empty body decodes to an empty document.
    public static func decode(_ data: Data) throws -> JSONAPIDocument {
        guard !data.isEmpty, data.contains(where: { !$0.isJSONWhitespace }) else { return JSONAPIDocument() }
        return try JSONDecoder().decode(JSONAPIDocument.self, from: data)
    }

    /// Encodes the document to a request body.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

extension UInt8 {
    fileprivate var isJSONWhitespace: Bool {
        self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D
    }
}
