import Foundation

extension Store {
    /// The cached live instance a to-one relationship points at, without a request.
    public func peek<T: Resource>(_ relationship: ToOne<T>) -> Live<T>? {
        relationship.key.flatMap { peek(T.self, key: $0) }
    }

    /// The cached live instances of a to-many relationship, in id order, skipping ids not in the cache.
    public func peek<T: Resource>(_ relationship: ToMany<T>) -> [Live<T>] {
        relationship.keys.compactMap { peek(T.self, key: $0) }
    }

    /// The live instance of a to-one relationship, fetching it when it is not cached.
    public func resolve<T: Resource>(_ relationship: ToOne<T>, cache: CacheOptions = .default) async throws -> Live<T>? {
        guard let key = relationship.key else { return nil }
        if !cache.reload, let live = peek(T.self, key: key) { return live }
        return try await findLive(T.self, id: key.id, cache: cache)
    }

    /// The live instances of a to-many relationship, fetching each id that is not cached (one find per gap).
    public func resolve<T: Resource>(_ relationship: ToMany<T>, cache: CacheOptions = .default) async throws -> [Live<T>] {
        var result: [Live<T>] = []
        for key in relationship.keys {
            if !cache.reload, let live = peek(T.self, key: key) {
                result.append(live)
                continue
            }
            result.append(try await findLive(T.self, id: key.id, cache: cache))
        }
        return result
    }
}
