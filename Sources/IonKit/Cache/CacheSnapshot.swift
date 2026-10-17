import Foundation

/// The store's caches as written to disk by `store.saveSnapshot()` and read back by `store.loadSnapshot()`: every
/// raw resource object with its tombstone flag, and every cached document (keys, links, meta, timing, ETag).
/// Live instances, in-flight requests, collections and mutation sequences are not part of it.
///
/// Apps do not build snapshots themselves; the type is public so its format is documented and testable.
///
/// Usage: `Store(baseURL: url, snapshotURL: URL.cachesDirectory.appending(path: "ionkit.json"))`
public struct CacheSnapshot: Codable, Sendable {
    /// The format this version of IonKit writes and reads; a file with any other version is discarded.
    public static let currentFormatVersion = 1

    /// One resource-cache entry: the latest raw object and whether it was deleted.
    ///
    /// Usage: `CacheSnapshot.Entry(object: Fixtures.object(person), isDeleted: false)`
    public struct Entry: Codable, Sendable {
        public var object: ResourceObject
        public var isDeleted: Bool

        public init(object: ResourceObject, isDeleted: Bool = false) {
            self.object = object
            self.isDeleted = isDeleted
        }
    }

    public var formatVersion: Int
    /// The base URL of the store that wrote the snapshot; a store with another base URL discards it.
    public var baseURL: URL
    public var resources: [Entry]
    /// Cached documents keyed by `RequestKey.value`.
    public var documents: [String: CachedDocument]

    public init(
        formatVersion: Int = CacheSnapshot.currentFormatVersion, baseURL: URL, resources: [Entry] = [],
        documents: [String: CachedDocument] = [:]
    ) {
        self.formatVersion = formatVersion
        self.baseURL = baseURL
        self.resources = resources
        self.documents = documents
    }

    /// Reads and decodes a snapshot file. Synchronous file I/O: call it off the main actor.
    static func read(from url: URL) throws -> CacheSnapshot {
        let data = try Data(contentsOf: url)
        return try makeDecoder().decode(CacheSnapshot.self, from: data)
    }

    /// Encodes the snapshot and writes it atomically (a temporary file renamed into place), creating the parent
    /// directory when needed. Synchronous file I/O: call it off the main actor.
    static func write(_ snapshot: CacheSnapshot, to url: URL) throws {
        let data = try makeEncoder().encode(snapshot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Deletes a snapshot file; a missing file is not an error.
    static func remove(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Dates use `Date`'s own encoding (seconds since 2001 as a number), which round-trips exactly: ISO 8601 would
    /// drop sub-second precision and could make an invalidation in the same second as its response look older.
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return decoder
    }
}
