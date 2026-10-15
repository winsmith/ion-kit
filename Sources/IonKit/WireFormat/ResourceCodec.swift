import Foundation

/// Why the codec rejected a resource object.
public enum CodecError: Error, Sendable, CustomStringConvertible {
    /// The object's `type` is not the struct's `resourceType`.
    case typeMismatch(expected: String, found: String)
    /// The object has no id but one was required.
    case missingID(type: String)
    /// The encoded struct was not a JSON object.
    case notAnObject
    /// A relationship on a draft references a client-local placeholder id.
    case localRelationship(String)

    public var description: String {
        switch self {
        case .typeMismatch(let expected, let found): "expected resource type \"\(expected)\", found \"\(found)\""
        case .missingID(let type): "resource of type \"\(type)\" has no id"
        case .notAnObject: "resource did not encode to a JSON object"
        case .localRelationship(let name): "relationship \"\(name)\" references a resource that has not been saved yet"
        }
    }
}

/// Maps `Resource` structs to and from `ResourceObject`s.
///
/// Decoding merges `id`, `attributes` and the relationship objects into one JSON object and runs `JSONDecoder`
/// over it; encoding runs `JSONEncoder` and moves the keys that `ToOne` / `ToMany` reported into
/// `relationships`. Codable synthesis, custom `CodingKeys`, optionals and key strategies keep working.
///
/// Usage: `let person: Person = try store.codec.decode(object)`
public struct ResourceCodec: Sendable {
    /// Applied when decoding attributes into the struct. Default: keys as-is (camelCase servers).
    public var keyDecodingStrategy: JSONDecoder.KeyDecodingStrategy
    /// Applied when encoding the struct into attributes. Default: keys as-is.
    public var keyEncodingStrategy: JSONEncoder.KeyEncodingStrategy

    public init(
        keyDecodingStrategy: JSONDecoder.KeyDecodingStrategy = .useDefaultKeys,
        keyEncodingStrategy: JSONEncoder.KeyEncodingStrategy = .useDefaultKeys
    ) {
        self.keyDecodingStrategy = keyDecodingStrategy
        self.keyEncodingStrategy = keyEncodingStrategy
    }

    /// A codec with the default strategies.
    public static let `default` = ResourceCodec()

    /// A codec for servers that send snake_case keys.
    public static let snakeCase = ResourceCodec(keyDecodingStrategy: .convertFromSnakeCase, keyEncodingStrategy: .convertToSnakeCase)

    // MARK: Decoding

    /// Decodes a wire object into a resource struct. Throws `IonError.decoding` on a type mismatch or a Codable failure.
    public func decode<T: Resource>(_ object: ResourceObject, as type: T.Type = T.self) throws(IonError) -> T {
        guard object.type == T.resourceType else {
            throw .decoding(object.key, CodecError.typeMismatch(expected: T.resourceType, found: object.type))
        }
        guard let id = object.id else {
            throw .decoding(nil, CodecError.missingID(type: object.type))
        }
        var merged = object.attributes
        merged["id"] = .string(id)
        for (name, relationship) in object.relationships {
            merged[name] = Self.json(for: relationship)
        }
        do {
            return try decodeMerged(merged, as: T.self)
        } catch {
            throw .decoding(object.key, error)
        }
    }

    /// Runs `JSONDecoder` over the merged object. A relationship property whose key the payload omitted
    /// must decode as `.unloaded`, but synthesized `Codable` throws `keyNotFound` for it; the codec then injects
    /// an empty relationship object for that key and retries, rethrowing the original error when the key turns out
    /// not to be a relationship.
    private func decodeMerged<T: Resource>(_ merged: [String: JSONValue], as type: T.Type) throws -> T {
        var merged = merged
        var injected: [String: any Error] = [:]
        let decoder = makeDecoder()
        while true {
            do {
                return try decoder.decode(T.self, from: try JSONEncoder().encode(JSONValue.object(merged)))
            } catch DecodingError.keyNotFound(let key, let context)
                where context.codingPath.isEmpty && injected[key.stringValue] == nil && injected.count < 64
            {
                injected[key.stringValue] = DecodingError.keyNotFound(key, context)
                merged[key.stringValue] = .object([:])
            } catch DecodingError.typeMismatch(_, let context)
                where context.codingPath.count == 1 && injected[context.codingPath[0].stringValue] != nil
            {
                throw injected[context.codingPath[0].stringValue]!
            }
        }
    }

    /// The `{"data": …}` object a relationship becomes inside the merged object.
    static func json(for relationship: RelationshipObject) -> JSONValue {
        switch relationship.data {
        case .none: .object([:])
        case .one(nil): .object(["data": .null])
        case .one(let identifier?): .object(["data": Self.json(for: identifier)])
        case .many(let identifiers): .object(["data": .array(identifiers.map(Self.json(for:)))])
        }
    }

    private static func json(for identifier: ResourceIdentifier) -> JSONValue {
        var object: [String: JSONValue] = ["type": .string(identifier.type), "id": .string(identifier.id)]
        if let lid = identifier.lid { object["lid"] = .string(lid) }
        if let meta = identifier.meta { object["meta"] = .object(meta) }
        return .object(object)
    }

    // MARK: Encoding

    /// Encodes a resource struct into a wire object. A client-local placeholder id becomes `id == nil`;
    /// `.unloaded` relationships are omitted.
    public func encode<T: Resource>(_ value: T) throws(IonError) -> ResourceObject {
        do {
            return try encodeUnchecked(value)
        } catch {
            throw .decoding(value.hasLocalID ? nil : value.resourceKey, error)
        }
    }

    private func encodeUnchecked<T: Resource>(_ value: T) throws -> ResourceObject {
        let collector = RelationshipKeyCollector()
        let encoder = makeEncoder()
        encoder.userInfo[.relationshipKeyCollector] = collector
        let data = try encoder.encode(value)
        guard case .object(var fields) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw CodecError.notAnObject
        }
        let id = fields.removeValue(forKey: "id")?.stringValue
        var relationships: [String: RelationshipObject] = [:]
        for path in collector.paths where path.count == 1 {
            let wireKey = wireKey(for: path)
            guard let json = fields.removeValue(forKey: wireKey) else { continue }
            let relationship: RelationshipObject = try json.decode()
            if relationship.data != nil {
                relationships[wireKey] = relationship
            }
        }
        return ResourceObject(
            type: T.resourceType,
            id: id.flatMap { T.isLocalID($0) ? nil : $0 },
            attributes: fields,
            relationships: relationships
        )
    }

    /// The key as it appears in the encoded JSON, after the key encoding strategy.
    private func wireKey(for path: [String]) -> String {
        switch keyEncodingStrategy {
        case .useDefaultKeys:
            return path.last!
        case .convertToSnakeCase:
            return Self.snakeCase(path.last!)
        case .custom(let convert):
            return convert(path.map(AnyCodingKey.init)).stringValue
        @unknown default:
            return path.last!
        }
    }

    /// The same conversion `JSONEncoder.KeyEncodingStrategy.convertToSnakeCase` applies.
    static func snakeCase(_ key: String) -> String {
        guard !key.isEmpty else { return key }
        var words: [Range<String.Index>] = []
        var wordStart = key.startIndex
        var searchRange = key.index(after: wordStart)..<key.endIndex
        while let upperRange = key.rangeOfCharacter(from: .uppercaseLetters, options: [], range: searchRange) {
            words.append(wordStart..<upperRange.lowerBound)
            searchRange = upperRange.lowerBound..<searchRange.upperBound
            guard let lowerRange = key.rangeOfCharacter(from: .lowercaseLetters, options: [], range: searchRange) else {
                wordStart = searchRange.lowerBound
                break
            }
            let afterCapital = key.index(after: upperRange.lowerBound)
            if lowerRange.lowerBound == afterCapital {
                wordStart = upperRange.lowerBound
            } else {
                let beforeLower = key.index(before: lowerRange.lowerBound)
                words.append(upperRange.lowerBound..<beforeLower)
                wordStart = beforeLower
            }
            searchRange = lowerRange.upperBound..<searchRange.upperBound
        }
        words.append(wordStart..<searchRange.upperBound)
        return words.map { key[$0].lowercased() }.joined(separator: "_")
    }

    // MARK: Diff

    /// The changed fields between two values of one resource, as the body of a PATCH: attributes whose encoded
    /// value differs (an attribute dropped from `value` is sent as null) and relationships whose encoded object
    /// differs. A relationship that is `.unloaded` in `value` is never sent.
    public func diff<T: Resource>(from original: T, to value: T) throws(IonError) -> ResourceObject {
        let before = try encode(original)
        let after = try encode(value)
        var result = ResourceObject(type: T.resourceType, id: after.id)
        for key in Set(before.attributes.keys).union(after.attributes.keys) {
            let old = before.attributes[key]
            let new = after.attributes[key]
            if old != new {
                result.attributes[key] = new ?? .null
            }
        }
        for (key, relationship) in after.relationships where before.relationships[key] != relationship {
            result.relationships[key] = relationship
        }
        return result
    }

    /// True when `object` carries no attributes and no relationships, i.e. a diff with nothing to send.
    public static func isEmptyChange(_ object: ResourceObject) -> Bool {
        object.attributes.isEmpty && object.relationships.isEmpty
    }

    /// Throws `IonError.invalidDraft` when a relationship references a client-local placeholder id.
    public func validateForSave(_ object: ResourceObject) throws(IonError) {
        for (name, relationship) in object.relationships {
            for identifier in relationship.data?.identifiers ?? [] where identifier.id.hasPrefix("local:") {
                throw .invalidDraft(CodecError.localRelationship(name).description)
            }
        }
    }

    // MARK: JSONDecoder / JSONEncoder

    /// A `JSONDecoder` configured with this codec's key strategy and IonKit's ISO 8601 date parsing.
    public func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = keyDecodingStrategy
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = ISO8601.parse(string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(string)")
            }
            return date
        }
        decoder.dataDecodingStrategy = .base64
        return decoder
    }

    /// A `JSONEncoder` configured with this codec's key strategy, sorted keys and ISO 8601 dates with fractional seconds.
    public func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = keyEncodingStrategy
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601.format(date))
        }
        encoder.dataEncodingStrategy = .base64
        return encoder
    }
}

/// ISO 8601 parsing that accepts timestamps with and without fractional seconds, and formatting with them.
public enum ISO8601 {
    /// Parses `2026-10-15T10:00:00Z`, `2026-10-15T10:00:00.123Z` and offset forms such as `+02:00`.
    public static func parse(_ string: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) { return date }
        if let date = try? Date.ISO8601FormatStyle().parse(string) { return date }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: string)
    }

    /// Formats as UTC with fractional seconds: `2026-10-15T10:00:00.123Z`.
    public static func format(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}
