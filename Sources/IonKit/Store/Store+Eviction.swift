import Foundation

extension Store {
    /// Evicts least recently used resources until at most `maxCachedResources` are left, or until only resources
    /// in use remain, and removes every cached document that lists an evicted resource, so no document ever
    /// materializes with gaps. Kept whatever their age: resources used after `clock` value `threshold` (by the
    /// operation that called this), a `Live` held outside the cache, what alive collections list, and an entry
    /// mutated after the oldest pending fetch started. Does nothing without a cap or below it.
    func evictIfNeeded(keepingUsedAfter threshold: Int) {
        guard let cap = maxCachedResources, resources.count > cap else { return }
        let inUse = keysOfAliveCollections()
        let oldestPendingFetch = pendingFetches.keys.min()
        var listing: [ResourceKey: [RequestKey]]?
        for key in resources.keysByLastUsed(through: threshold) {
            guard resources.count > cap else { break }
            guard !inUse.contains(key) else { continue }
            // A GET sent before this key's last local mutation is still on its way: its response is rejected only
            // while the entry remembers the mutation.
            if let oldestPendingFetch, resources.mutationSequence(of: key) > oldestPendingFetch { continue }
            guard !resources.isHeld(key) else { continue }
            resources.remove(key)
            if listing == nil { listing = requests.documentsByResource() }
            for requestKey in listing?[key] ?? [] {
                requests[requestKey] = nil
            }
        }
    }

    /// Everything an alive collection shows or would show again from its cached first page.
    private func keysOfAliveCollections() -> Set<ResourceKey> {
        var keys = Set<ResourceKey>()
        for collection in aliveCollections(ofType: nil) {
            keys.formUnion(collection.loadedKeys)
            if let document = requests[collection.key] {
                keys.formUnion(document.allKeys)
            }
        }
        return keys
    }
}
