import Foundation

extension Store {
    /// Saves a draft: POST for a new resource, PATCH with only the changed fields otherwise. On success the
    /// response is upserted (the server's version wins), cached queries of the type are invalidated, alive
    /// collections reload, and the draft's `original` becomes its `value`. Without changes no request is sent.
    ///
    /// Throws `IonError.invalidDraft` when a relationship references an unsaved resource, `IonError.http`
    /// (with `errors(forAttribute:)`) when the server rejects the save. Nothing in the cache changes on failure.
    ///
    /// Usage: `let live = try await store.save(&draft)`
    @discardableResult
    public func save<T: Resource>(_ draft: inout Draft<T>) async throws -> Live<T> {
        let request: Request<JSONAPIDocument>
        if let original = draft.original {
            guard draft.value.id == original.id else {
                throw IonError.invalidDraft("the id of \(T.resourceType)/\(original.id) was changed to \(draft.value.id)")
            }
            let diff = try codec.diff(from: original, to: draft.value)
            if ResourceCodec.isEmptyChange(diff) {
                return try existingLive(for: draft.value)
            }
            try codec.validateForSave(diff)
            let key = ResourceKey(T.self, id: original.id)
            request = Request(
                method: .patch, path: "\(T.collectionPath)/\(original.id)",
                body: try encodeBody(diff), op: .update, records: [key], cache: CacheOptions(types: [T.resourceType])
            )
        } else {
            let object = try codec.encode(draft.value)
            try codec.validateForSave(object)
            request = Request(
                method: .post, path: T.collectionPath,
                body: try encodeBody(object), op: .create, cache: CacheOptions(types: [T.resourceType])
            )
        }

        let raw = try RawRequest(request, baseURL: baseURL)
        let fetched = try await send(raw)

        var primary = fetched.document.data?.objects.first
        if primary == nil {
            // HTTP 204 or an empty body: the server accepted the resource as sent.
            guard !draft.isNew else {
                throw IonError.decoding(nil, CodecError.missingID(type: T.resourceType))
            }
            primary = try codec.encode(draft.value)
        }
        guard let object = primary, let key = object.key else {
            throw IonError.decoding(nil, CodecError.missingID(type: T.resourceType))
        }
        let value: T = try codec.decodeUntyped(object)

        mutationCounter += 1
        let sequence = mutationCounter
        resources.upsert(object, typed: value, codec: codec, startSequence: sequence)
        resources.bump(key, sequence: sequence)
        for other in fetched.document.allObjects where other.key != key {
            resources.upsert(other, codec: codec, startSequence: sequence)
        }
        let live = try liveResource(for: key, as: T.self)
        draft.markSaved(id: key.id)
        invalidate(type: T.resourceType)
        return live
    }

    /// Sends DELETE, tombstones the entry, flags `live.isDeleted`, removes the item from every alive collection of
    /// the type at once and invalidates cached queries of it. Views holding the instance should dismiss on `isDeleted`.
    /// A 404 means the resource is already gone (deleted on another device, or a retried DELETE whose first attempt
    /// landed) and counts as success.
    ///
    /// Usage: `try await store.delete(live)`
    public func delete<T: Resource>(_ live: Live<T>) async throws {
        let key = live.key
        let request = Request<JSONAPIDocument>(
            method: .delete, path: "\(T.collectionPath)/\(key.id)", op: .delete, records: [key],
            cache: CacheOptions(types: [T.resourceType])
        )
        let raw = try RawRequest(request, baseURL: baseURL)
        let fetched = try await send(raw, accepting: [404])

        mutationCounter += 1
        let sequence = mutationCounter
        for object in fetched.document.allObjects where object.key != key {
            resources.upsert(object, codec: codec, startSequence: sequence)
        }
        resources.tombstone(key, sequence: sequence)
        for collection in aliveCollections(ofType: T.resourceType) {
            collection.remove(key)
        }
        invalidate(type: T.resourceType)
    }

    // MARK: Helpers

    private func encodeBody(_ object: ResourceObject) throws -> Data {
        try JSONAPIDocument(one: object).encoded()
    }

    /// The live instance for an unchanged draft: the cached one, or one created from the draft's value.
    private func existingLive<T: Resource>(for value: T) throws -> Live<T> {
        let key = value.resourceKey
        if let live = try resources.live(for: key, as: T.self, codec: codec) {
            return live
        }
        resources.upsert(try codec.encode(value), typed: value, codec: codec, startSequence: mutationCounter)
        return try liveResource(for: key, as: T.self)
    }
}

extension ResourceCodec {
    /// `decode` with plain `throws`, for generic async callers (see `ResourceCache.live`).
    func decodeUntyped<T: Resource>(_ object: ResourceObject) throws -> T {
        try decode(object)
    }
}
