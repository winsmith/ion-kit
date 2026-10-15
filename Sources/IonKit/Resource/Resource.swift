import Foundation

/// A resource is a flat `Codable` struct: its stored properties are the JSON:API attributes, properties typed
/// `ToOne` / `ToMany` are its relationships, and `id` is the resource id. The Swift type is the schema.
///
/// Usage:
/// ```swift
/// struct Person: Resource {
///     static let resourceType = "person"
///     static let collectionPath = "people"
///     var id: String
///     var name: String
///     var tags: ToMany<Tag> = .unloaded
/// }
/// ```
public protocol Resource: Codable, Sendable, Equatable {
    /// JSON:API `type`, e.g. "person".
    static var resourceType: String { get }
    /// Collection path relative to the store's base URL. Default: `resourceType + "s"`.
    static var collectionPath: String { get }
    /// Server-assigned id. A new draft carries a client-local placeholder (`local:<uuid>`) that is never sent.
    var id: String { get set }
}

extension Resource {
    public static var collectionPath: String { resourceType + "s" }

    /// The cache key of this value.
    public var resourceKey: ResourceKey { ResourceKey(type: Self.resourceType, id: id) }

    /// True while the id is a client-local placeholder from `Draft(new:)`.
    public var hasLocalID: Bool { Self.isLocalID(id) }

    /// The prefix of client-local placeholder ids.
    public static var localIDPrefix: String { "local:" }

    /// True when `id` is a client-local placeholder that must never reach the server.
    public static func isLocalID(_ id: String) -> Bool { id.hasPrefix(localIDPrefix) }

    /// A fresh client-local placeholder id.
    public static func makeLocalID() -> String { localIDPrefix + UUID().uuidString.lowercased() }
}
