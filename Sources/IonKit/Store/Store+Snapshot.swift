import Foundation

extension Store {
    /// Reads the snapshot at `snapshotURL` and fills the caches with it, so a cold launch renders last session's
    /// data before the first response. Call it once, before the first request. Decoding runs off the main actor.
    ///
    /// Restored documents are served as stale whatever their age and the cache policy say (so each one is
    /// refetched in the background on its first load), except one that was invalidated before it was saved, which
    /// is expired. Resources and documents already in RAM win over the snapshot, and alive collections are not
    /// touched. A missing, unreadable or corrupt file, one written by another format version or for another base
    /// URL, and a load that `clear()` overtook all leave the caches as they were and return false; the file is not
    /// touched. Without a `snapshotURL` this does nothing and returns false.
    ///
    /// Usage: `await store.loadSnapshot()`
    @discardableResult
    public func loadSnapshot() async -> Bool {
        guard let url = snapshotURL else { return false }
        let generation = snapshotGeneration
        let pending = snapshotTail
        let snapshot = await Task.detached(priority: .userInitiated) {
            _ = await pending?.value
            return try? CacheSnapshot.read(from: url)
        }.value
        guard generation == snapshotGeneration, let snapshot,
              snapshot.formatVersion == CacheSnapshot.currentFormatVersion,
              snapshot.baseURL.absoluteString == baseURL.absoluteString
        else { return false }
        for entry in snapshot.resources {
            resources.restore(entry.object, isDeleted: entry.isDeleted)
        }
        for (key, document) in snapshot.documents {
            requests.restore(document, for: RequestKey(key))
        }
        evictIfNeeded(keepingUsedAfter: resources.clock)
        return true
    }

    /// Writes every cached resource (tombstones included) and document to `snapshotURL`, atomically. The caches
    /// are copied when this is called; encoding and writing run off the main actor, and saves and `clear()` reach
    /// the disk in call order. Returns false when encoding or writing failed, or without a `snapshotURL`.
    ///
    /// Usage: `.onChange(of: scenePhase) { if $0 == .background { Task { await store.saveSnapshot() } } }`
    @discardableResult
    public func saveSnapshot() async -> Bool {
        guard let url = snapshotURL else { return false }
        var documents: [String: CachedDocument] = [:]
        for (key, document) in requests.entries {
            documents[key.value] = document
        }
        let snapshot = CacheSnapshot(baseURL: baseURL, resources: resources.snapshotEntries(), documents: documents)
        let task = enqueueSnapshotWork {
            do {
                try CacheSnapshot.write(snapshot, to: url)
                return true
            } catch {
                return false
            }
        }
        return await task.value
    }

    /// Runs file work off the main actor after the work enqueued before it, and makes it the new tail.
    @discardableResult
    func enqueueSnapshotWork(_ work: @escaping @Sendable () -> Bool) -> Task<Bool, Never> {
        let previous = snapshotTail
        let task = Task.detached(priority: .utility) {
            _ = await previous?.value
            return work()
        }
        snapshotTail = task
        return task
    }
}
