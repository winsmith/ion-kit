import Foundation

/// What the policy says about a cached document.
public enum CacheState: Sendable, Hashable {
    /// Serve it.
    case fresh
    /// Serve it and refetch in the background.
    case stale
    /// Fetch and wait.
    case expired
}

/// Decides whether a cached document is fresh, stale or expired.
///
/// Usage: `Store(baseURL: url, cachePolicy: DefaultCachePolicy(soft: 30, hard: 3600))`
public protocol CachePolicy: Sendable {
    func state(of entry: CachedDocument, now: Date) -> CacheState
}

/// Soft and hard expiry in seconds, honoring the server's `Cache-Control: max-age` / `Expires` when present.
///
/// A document is expired when it was invalidated after it was received, when the server's expiry has passed,
/// or when it is older than `hard`; stale when older than `soft`; fresh otherwise.
public struct DefaultCachePolicy: CachePolicy {
    /// Age after which a document is served but refetched in the background. Default: 1 minute.
    public var soft: TimeInterval
    /// Age after which a document is not served without a refetch. Default: 24 hours.
    public var hard: TimeInterval
    /// Whether `Cache-Control` / `Expires` from the response shorten the hard expiry. Default: true.
    public var honorsServerHeaders: Bool

    public init(soft: TimeInterval = 60, hard: TimeInterval = 24 * 60 * 60, honorsServerHeaders: Bool = true) {
        self.soft = soft
        self.hard = hard
        self.honorsServerHeaders = honorsServerHeaders
    }

    public func state(of entry: CachedDocument, now: Date) -> CacheState {
        if let invalidatedAt = entry.invalidatedAt, invalidatedAt > entry.receivedAt { return .expired }
        if honorsServerHeaders, let expiry = entry.serverExpiry, expiry <= now { return .expired }
        let age = now.timeIntervalSince(entry.receivedAt)
        if age >= hard { return .expired }
        if age >= soft { return .stale }
        return .fresh
    }
}

/// Never serves from the cache: every GET waits for the network. Handy in tests.
public struct NoCachePolicy: CachePolicy {
    public init() {}

    public func state(of entry: CachedDocument, now: Date) -> CacheState { .expired }
}
