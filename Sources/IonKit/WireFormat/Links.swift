import Foundation

/// One JSON:API link: a bare URL string or a link object with `href` and optional members.
///
/// Usage: `if let next = document.links?.next { request(next.href) }`
public struct Link: Hashable, Sendable {
    public var href: String
    public var rel: String?
    public var describedby: String?
    public var title: String?
    public var type: String?
    public var hreflang: String?
    public var meta: [String: JSONValue]?

    public init(
        href: String, rel: String? = nil, describedby: String? = nil, title: String? = nil,
        type: String? = nil, hreflang: String? = nil, meta: [String: JSONValue]? = nil
    ) {
        self.href = href
        self.rel = rel
        self.describedby = describedby
        self.title = title
        self.type = type
        self.hreflang = hreflang
        self.meta = meta
    }

    /// The link as a URL, when `href` parses as one.
    public var url: URL? { URL(string: href) }
}

extension Link: Codable {
    private enum CodingKeys: String, CodingKey {
        case href, rel, describedby, title, type, hreflang, meta
    }

    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let href = try? single.decode(String.self) {
            self.init(href: href)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            href: try container.decode(String.self, forKey: .href),
            rel: try container.decodeIfPresent(String.self, forKey: .rel),
            describedby: try container.decodeIfPresent(String.self, forKey: .describedby),
            title: try container.decodeIfPresent(String.self, forKey: .title),
            type: try container.decodeIfPresent(String.self, forKey: .type),
            hreflang: try container.decodeIfPresent(String.self, forKey: .hreflang),
            meta: try container.decodeIfPresent([String: JSONValue].self, forKey: .meta)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        let isBare = rel == nil && describedby == nil && title == nil && type == nil && hreflang == nil && meta == nil
        if isBare {
            var container = encoder.singleValueContainer()
            try container.encode(href)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(href, forKey: .href)
        try container.encodeIfPresent(rel, forKey: .rel)
        try container.encodeIfPresent(describedby, forKey: .describedby)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(hreflang, forKey: .hreflang)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

/// A JSON:API links object. Members whose value is `null` on the wire are absent here.
///
/// Usage: `collection.links.next?.href`
public struct Links: Hashable, Sendable {
    /// Every link by its member name.
    public var all: [String: Link]

    public init(_ all: [String: Link] = [:]) {
        self.all = all
    }

    public subscript(name: String) -> Link? {
        get { all[name] }
        set { all[name] = newValue }
    }

    public var selfLink: Link? { all["self"] }
    public var related: Link? { all["related"] }
    public var describedby: Link? { all["describedby"] }
    public var first: Link? { all["first"] }
    public var last: Link? { all["last"] }
    public var prev: Link? { all["prev"] }
    public var next: Link? { all["next"] }
    public var isEmpty: Bool { all.isEmpty }
}

extension Links: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        var links: [String: Link] = [:]
        for key in container.allKeys {
            if try container.decodeNil(forKey: key) { continue }
            links[key.stringValue] = try container.decode(Link.self, forKey: key)
        }
        self.init(links)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        for (name, link) in all.sorted(by: { $0.key < $1.key }) {
            try container.encode(link, forKey: AnyCodingKey(name))
        }
    }
}

/// A coding key for member names only known at runtime.
struct AnyCodingKey: CodingKey, Hashable {
    var stringValue: String
    var intValue: Int? { nil }

    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
