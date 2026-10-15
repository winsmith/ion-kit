import Foundation

/// A cached response: the keys of its resources (not copies), its links and meta, and the timing the policy needs.
/// A cached collection always materializes from the current live instances.
public struct CachedDocument: Sendable {
    public var primary: [ResourceKey]
    public var included: [ResourceKey]
    /// True when the primary data was a list (`"data": [ … ]`).
    public var isCollection: Bool
    public var links: Links
    public var meta: [String: JSONValue]?
    public var op: Operation
    public var receivedAt: Date
    public var invalidatedAt: Date?
    /// Resource types whose mutations invalidate this entry.
    public var types: Set<String>?
    /// When the server says the response expires (`Cache-Control: max-age` or `Expires`).
    public var serverExpiry: Date?

    public init(
        primary: [ResourceKey], included: [ResourceKey] = [], isCollection: Bool, links: Links = Links(),
        meta: [String: JSONValue]? = nil, op: Operation = .custom, receivedAt: Date = Date(), invalidatedAt: Date? = nil,
        types: Set<String>? = nil, serverExpiry: Date? = nil
    ) {
        self.primary = primary
        self.included = included
        self.isCollection = isCollection
        self.links = links
        self.meta = meta
        self.op = op
        self.receivedAt = receivedAt
        self.invalidatedAt = invalidatedAt
        self.types = types
        self.serverExpiry = serverExpiry
    }
}

/// `[RequestKey: CachedDocument]`, owned by the store.
@MainActor
final class RequestCache {
    private(set) var entries: [RequestKey: CachedDocument] = [:]

    subscript(key: RequestKey) -> CachedDocument? {
        get { entries[key] }
        set { entries[key] = newValue }
    }

    /// Marks every query of the type as invalidated.
    func invalidate(type: String, now: Date = Date()) {
        for (key, entry) in entries where entry.op == .query && entry.types?.contains(type) == true {
            entries[key]?.invalidatedAt = now
        }
    }

    /// Marks every entry that lists the key among its primary resources as invalidated.
    func invalidate(key: ResourceKey, now: Date = Date()) {
        for (requestKey, entry) in entries where entry.primary.contains(key) {
            entries[requestKey]?.invalidatedAt = now
        }
    }

    func removeAll() {
        entries.removeAll()
    }
}

/// Reads the caching headers of a response.
enum CacheHeaders {
    struct Directives {
        var noStore = false
        var noCache = false
        var maxAge: TimeInterval?
    }

    static func directives(in response: RawResponse) -> Directives {
        var directives = Directives()
        guard let header = response.header("Cache-Control") else { return directives }
        for part in header.split(separator: ",") {
            let directive = part.trimmingCharacters(in: .whitespaces).lowercased()
            if directive == "no-store" {
                directives.noStore = true
            } else if directive == "no-cache" {
                directives.noCache = true
            } else if directive.hasPrefix("max-age="), let seconds = TimeInterval(directive.dropFirst("max-age=".count)) {
                directives.maxAge = seconds
            }
        }
        return directives
    }

    /// The instant the response expires according to its headers, relative to `receivedAt`.
    static func expiry(of response: RawResponse, receivedAt: Date) -> Date? {
        let directives = directives(in: response)
        if directives.noCache { return receivedAt }
        if let maxAge = directives.maxAge {
            let age = response.header("Age").flatMap(TimeInterval.init) ?? 0
            return receivedAt.addingTimeInterval(maxAge - age)
        }
        if let expires = response.header("Expires").flatMap(parseHTTPDate) {
            let serverNow = response.header("Date").flatMap(parseHTTPDate) ?? receivedAt
            return receivedAt.addingTimeInterval(expires.timeIntervalSince(serverNow))
        }
        return nil
    }

    static func parseHTTPDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }
}
