import Foundation

/// Where a JSON:API error applies: a JSON pointer into the request document, a query parameter, or a header.
public struct ErrorSource: Hashable, Sendable, Codable {
    public var pointer: String?
    public var parameter: String?
    public var header: String?

    public init(pointer: String? = nil, parameter: String? = nil, header: String? = nil) {
        self.pointer = pointer
        self.parameter = parameter
        self.header = header
    }

    /// The attribute name when `pointer` is `/data/attributes/<name>`.
    public var attribute: String? {
        guard let pointer, pointer.hasPrefix("/data/attributes/") else { return nil }
        return String(pointer.dropFirst("/data/attributes/".count))
    }

    /// The relationship name when `pointer` is `/data/relationships/<name>`.
    public var relationship: String? {
        guard let pointer, pointer.hasPrefix("/data/relationships/") else { return nil }
        let rest = pointer.dropFirst("/data/relationships/".count)
        return String(rest.split(separator: "/").first ?? rest)
    }
}

/// A JSON:API error object with every member the spec defines.
///
/// Usage: `error.detail ?? error.title ?? "Unknown error"`
public struct ErrorObject: Hashable, Sendable, Codable {
    public var id: String?
    public var status: String?
    public var code: String?
    public var title: String?
    public var detail: String?
    public var source: ErrorSource?
    public var links: Links?
    public var meta: [String: JSONValue]?

    public init(
        id: String? = nil, status: String? = nil, code: String? = nil, title: String? = nil,
        detail: String? = nil, source: ErrorSource? = nil, links: Links? = nil, meta: [String: JSONValue]? = nil
    ) {
        self.id = id
        self.status = status
        self.code = code
        self.title = title
        self.detail = detail
        self.source = source
        self.links = links
        self.meta = meta
    }

    /// `status` as a number, when the server sent one.
    public var statusCode: Int? { status.flatMap(Int.init) }
}
