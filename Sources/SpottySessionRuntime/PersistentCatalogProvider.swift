import Foundation
import SpottyCatalogStorage
import SpottyDiagnostics
import SpottyDomain
import SpottyRuntimeContracts

package protocol CatalogCacheLifecycle: Sendable {
    func activate(accountEpoch: UInt64) async
    /// False means account content remains fenced but could not be removed from disk.
    func retire(accountEpoch: UInt64, purge: Bool) async -> Bool
}

/// Account-stamped gateway reads with an optional persistent browsing cache. A verified profile
/// binds the database to the current account; a stored selector never substitutes for that proof.
/// Writes and Connect ordering deliberately do not pass through this cache.
package actor PersistentCatalogProvider: CatalogProviding, CatalogCacheLifecycle, CatalogEntityQueryProviding {
    private let source: any CatalogProviding
    private let rootDirectory: URL
    private let clock: any PlaybackClock
    private var generation: UInt64 = 0
    private var highestAccountEpoch: UInt64 = 0
    private var retiredThrough: UInt64?
    private var active = false
    private var storage: PersistentCatalog?
    private var accountURI: String?
    private var accountVerified = false
    private var cleanupFailed = false
    private var retirementInProgress = false
    private var accountMismatch = false
    private var cacheRevision: UInt64 = 0
    private var cacheWritesInFlight = 0
    private var cacheWriteWaiters: [CheckedContinuation<Void, Never>] = []
    // Only outstanding keys are retained; completed requests leave no historical bookkeeping.
    private var collectionReads: [String: UInt64] = [:]
    private var nextCollectionReadID: UInt64 = 0

    private struct CollectionRead {
        let key: String
        let id: UInt64
        let fetchedAt: Date
    }
    private var libraryReadRevision: UInt64 = 0
    private var accountLifetime = UUID()
    private enum EntityQueryAvailability { case unbound, available, degraded }
    private var entityQueryAvailability: EntityQueryAvailability = .unbound
    private var entityObservations = CatalogEntityObservations()

    package init(
        source: any CatalogProviding,
        rootDirectory: URL,
        clock: any PlaybackClock = SystemPlaybackClock()
    ) {
        self.source = source
        self.rootDirectory = rootDirectory
        self.clock = clock
    }

    deinit {
        entityObservations.finishAll()
    }

    package func activate(accountEpoch: UInt64) async {
        guard accountEpoch >= highestAccountEpoch, retiredThrough.map({ accountEpoch > $0 }) ?? true else { return }
        guard !active, !cleanupFailed, !retirementInProgress, !accountMismatch else { return }
        highestAccountEpoch = accountEpoch
        advanceGeneration()
        accountLifetime = UUID()
        entityQueryAvailability = .unbound
        active = true
    }

    package func retire(accountEpoch: UInt64, purge: Bool) async -> Bool {
        retiredThrough = max(retiredThrough ?? 0, accountEpoch)
        // An old completion cannot close or delete a replacement account's database. Record
        // retirement even before first activation so a queued old activation remains inert.
        guard accountEpoch >= highestAccountEpoch else { return true }
        highestAccountEpoch = accountEpoch
        // A competing retirement cannot clear this owner's storage or reopen admission while
        // its disk operation is suspended. A false result keeps the caller's cleanup fence.
        guard !retirementInProgress else { return false }
        retirementInProgress = true
        defer { retirementInProgress = false }
        active = false
        advanceGeneration()
        entityObservations.finishAll()
        accountURI = nil
        accountVerified = false
        do {
            if let storage {
                if purge {
                    try await storage.retire(scope: storage.scope)
                } else {
                    try await storage.close(scope: storage.scope)
                }
            }
            if purge {
                // Sign-out can precede this process's first verified profile. Cleanup must
                // still remove prior retained partitions; those files never authorize reads.
                try await PersistentCatalog.purgeRetainedAccounts(rootDirectory: rootDirectory)
            } else if cleanupFailed {
                // Retention cannot turn an unfinished purge into successful cleanup.
                return false
            }
            self.storage = nil
            cleanupFailed = false
            accountMismatch = false
            return true
        } catch {
            cleanupFailed = true
            SpottyLog.catalog.error("Account catalog cleanup failed; retained content remains fenced")
            return false
        }
    }

    package func profile() async throws -> CatalogProfileSnapshot {
        let stamp = try admission()
        let profile = try await read { try await $0.profile() }
        try validate(stamp)
        guard let uri = profile.uri, uri.hasPrefix("spotify:user:"), !uri.dropFirst(13).isEmpty else {
            if accountURI != nil {
                active = false
                advanceGeneration()
                accountMismatch = true
                entityObservations.finishAll()
                throw CatalogReadFailure.sessionExpired
            }
            return profile
        }
        if let accountURI, accountURI != uri {
            // A grant changed without its expected retirement. Refuse both accounts until the
            // runtime performs the normal boundary; never rebind live requests by convenience.
            active = false
            advanceGeneration()
            accountMismatch = true
            entityObservations.finishAll()
            throw CatalogReadFailure.sessionExpired
        }
        let database: PersistentCatalog
        if let storage {
            database = storage
        } else {
            accountURI = uri
            database = PersistentCatalog(rootDirectory: rootDirectory, accountID: uri)
            storage = database
        }
        // Retain the original account owner after an unavailable open, but retry it when fresh
        // same-account proof arrives. A failed/rejected write is a different state: reopening
        // cannot establish that the cache contains every live result missed in this lifetime.
        accountVerified = true
        guard entityQueryAvailability == .unbound else { return profile }
        do {
            try await database.open(scope: database.scope)
            try validate(stamp)
            if entityQueryAvailability == .unbound { entityQueryAvailability = .available }
        } catch {
            // Browsing can continue from the gateway when the cache is denied or damaged.
            // Keep the owner so retirement still attempts to purge its account content.
            SpottyLog.catalog.warning("Persistent catalog unavailable; live browsing remains available")
        }
        try validate(stamp)
        return profile
    }

    package func playlist(id: String) async throws -> CatalogPlaylistSnapshot {
        let stamp = try admission()
        let request = beginCollectionRead("spotify:playlist:\(id)")
        defer { finishCollectionRead(request) }
        do {
            let value = try await read { try await $0.playlist(id: id) }
            try validate(stamp)
            await persist(
                request: request, tracks: value.tracks,
                metadata: CatalogCollectionMetadata(
                    item: value.item, description: value.description, ownerURI: value.ownerURI
                ), stamp: stamp
            )
            try validate(stamp)
            return value
        } catch {
            try validate(stamp)
            guard Self.allowsCachedRead(after: error), let cached = try await cachedPlaylist(id: id)
            else { throw error }
            return cached
        }
    }

    package func album(id: String) async throws -> CatalogAlbumSnapshot {
        let stamp = try admission()
        let request = beginCollectionRead("spotify:album:\(id)")
        defer { finishCollectionRead(request) }
        do {
            let value = try await read { try await $0.album(id: id) }
            try validate(stamp)
            await persist(
                request: request, tracks: value.tracks,
                metadata: CatalogCollectionMetadata(
                    item: value.item, releaseDate: value.releaseDate, playCounts: value.playCounts,
                    albumArtists: value.artists),
                stamp: stamp
            )
            try validate(stamp)
            return value
        } catch {
            try validate(stamp)
            guard Self.allowsCachedRead(after: error), let cached = try await cachedAlbum(id: id)
            else { throw error }
            return cached
        }
    }

    package func cachedPlaylist(id: String) async throws -> CatalogPlaylistSnapshot? {
        let stamp = try admission()
        guard let cached = try await cachedCollection("spotify:playlist:\(id)", stamp: stamp) else { return nil }
        return CatalogPlaylistSnapshot(
            description: cached.metadata.description, ownerURI: nil, tracks: cached.occurrences.map(\.track),
            item: Self.withoutOwnership(cached.metadata.item),
            freshness: .cached(fetchedAt: cached.fetchedAt))
    }

    package func cachedAlbum(id: String) async throws -> CatalogAlbumSnapshot? {
        let stamp = try admission()
        guard let cached = try await cachedCollection("spotify:album:\(id)", stamp: stamp) else { return nil }
        return CatalogAlbumSnapshot(
            tracks: cached.occurrences.map(\.track), releaseDate: cached.metadata.releaseDate,
            item: cached.metadata.item, freshness: .cached(fetchedAt: cached.fetchedAt),
            playCounts: cached.metadata.playCounts, artists: cached.metadata.albumArtists)
    }

    package func searchTracks(_ term: String, limit: Int) async throws -> [CatalogTrack] {
        try await read { try await $0.searchTracks(term, limit: limit) }
    }
    package func searchAlbums(_ term: String, limit: Int) async throws -> [CatalogItem] {
        try await read { try await $0.searchAlbums(term, limit: limit) }
    }
    package func searchArtists(_ term: String, limit: Int) async throws -> [CatalogItem] {
        try await read { try await $0.searchArtists(term, limit: limit) }
    }
    package func searchPlaylists(_ term: String, limit: Int) async throws -> [CatalogItem] {
        try await read { try await $0.searchPlaylists(term, limit: limit) }
    }
    package func home() async throws -> CatalogHomeSnapshot {
        try await read { try await $0.home() }
    }
    package func playlistLibrary() async throws -> [PlaylistLibraryNode] {
        let stamp = try admission()
        libraryReadRevision &+= 1
        let revision = libraryReadRevision
        let fetchedAt = clock.now()
        let nodes = try await read { try await $0.playlistLibrary() }
        try validate(stamp)
        if revision == libraryReadRevision, accountVerified, let storage {
            do {
                try await storage.replacePlaylistLibrary(
                    CatalogPlaylistLibraryRecord(nodes: nodes, fetchedAt: fetchedAt), scope: storage.scope,
                    admissionOrdinal: revision)
            } catch {
                SpottyLog.catalog.warning("Playlist library could not be retained")
            }
        }
        try validate(stamp)
        return nodes
    }

    package func cachedPlaylistLibrary() async throws -> CatalogPlaylistLibrarySnapshot? {
        let stamp = try admission()
        guard let storage, accountVerified else { return nil }
        do {
            let saved = try await storage.playlistLibrary(scope: storage.scope)
            try validate(stamp)
            guard let record = saved else { return nil }
            return CatalogPlaylistLibrarySnapshot(
                nodes: record.nodes.map(\.withoutOwnership), fetchedAt: record.fetchedAt)
        } catch is CatalogStorageError {
            try validate(stamp)
            return nil
        }
    }
    package func libraryAlbums() async throws -> [CatalogItem] {
        try await read { try await $0.libraryAlbums() }
    }
    package func libraryArtists() async throws -> [CatalogItem] {
        try await read { try await $0.libraryArtists() }
    }
    package func libraryTracks() async throws -> [CatalogTrack] {
        try await read { try await $0.libraryTracks() }
    }
    package func artist(id: String) async throws -> CatalogArtistSnapshot {
        try await read { try await $0.artist(id: id) }
    }
    package func artistDiscography(id: String) async throws -> CatalogArtistSnapshot {
        try await read { try await $0.artistDiscography(id: id) }
    }

    private func read<T: Sendable>(
        _ operation: @Sendable (any CatalogProviding) async throws -> T
    ) async throws -> T {
        let stamp = try admission()
        do {
            let value = try await operation(source)
            try validate(stamp)
            return value
        } catch {
            try validate(stamp)
            if error as? CatalogReadFailure == .sessionExpired {
                // A refused grant invalidates the proof that admitted saved content. A later
                // live profile must verify it again; already suspended cache reads are fenced.
                accountVerified = false
                advanceGeneration()
                entityObservations.finishAll()
            }
            throw error
        }
    }

    private func admission() throws -> UInt64 {
        try validate(generation)
        return generation
    }

    private func validate(_ stamp: UInt64) throws {
        try Task.checkCancellation()
        guard active, !cleanupFailed, !retirementInProgress, !accountMismatch, stamp == generation else {
            throw CatalogReadFailure.sessionExpired
        }
    }

    private func advanceGeneration() {
        generation &+= 1
        collectionReads.removeAll(keepingCapacity: false)
    }

    private func beginCollectionRead(_ key: String) -> CollectionRead {
        nextCollectionReadID &+= 1
        let request = CollectionRead(key: key, id: nextCollectionReadID, fetchedAt: clock.now())
        collectionReads[key] = request.id
        return request
    }

    private func finishCollectionRead(_ request: CollectionRead) {
        if collectionReads[request.key] == request.id {
            collectionReads.removeValue(forKey: request.key)
        }
    }

    private func beginCacheWrite() async {
        cacheWritesInFlight += 1
        guard cacheWritesInFlight > 1 else { return }
        await withCheckedContinuation { cacheWriteWaiters.append($0) }
    }

    private func finishCacheWrite() {
        cacheWritesInFlight -= 1
        if cacheWriteWaiters.isEmpty {
            entityObservations.writesDrained()
        } else {
            cacheWriteWaiters.removeFirst().resume()
        }
    }

    private func persist(
        request: CollectionRead, tracks: [CatalogTrack], metadata: CatalogCollectionMetadata, stamp: UInt64
    ) async {
        guard active, stamp == generation, accountVerified, let storage else { return }
        // Hold the write turn through the storage await. A newer response cannot commit first
        // and then be overwritten by a previously queued write, even at equal clock samples.
        await beginCacheWrite()
        defer { finishCacheWrite() }
        guard !Task.isCancelled, active, stamp == generation, accountVerified,
            collectionReads[request.key] == request.id
        else { return }
        cacheRevision &+= 1
        do {
            let changes = try await storage.replaceCollection(
                CatalogCollectionWrite(
                    key: request.key, occurrences: CatalogOccurrence.browsingRows(tracks),
                    completeness: .complete, fetchedAt: request.fetchedAt, metadata: metadata,
                    admissionOrdinal: request.id
                ), scope: storage.scope
            )
            guard active, stamp == generation else { return }
            guard !changes.collectionWriteRejected else {
                disableEntityQueries()
                return
            }
            entityObservations.committed(changedURIs: changes.trackURIs)
        } catch {
            guard active, stamp == generation else { return }
            disableEntityQueries()
            SpottyLog.catalog.warning("Catalog result could not be retained")
        }
    }

    package func subscribeCatalogEntities(_ uris: Set<String>) async throws -> CatalogEntitySubscription {
        _ = try admission()
        guard entityQueryAvailability == .available, storage != nil, accountVerified else {
            throw CatalogEntityQueryFailure.unavailable
        }
        return try entityObservations.subscribe(uris, accountLifetime: accountLifetime) { [weak self] token in
            Task { await self?.unsubscribeCatalogEntities(token) }
        }
    }

    package func catalogEntities(for change: CatalogEntityChange) async throws -> [String: CatalogTrackMetadata] {
        let stamp = try admission()
        let writeRevision = cacheRevision
        let uris = Array(try entityReadURIs(change, stamp: stamp, writeRevision: writeRevision))
        guard let storage else { throw CatalogEntityQueryFailure.unavailable }
        // Results are unordered. Snapshot membership once; no public cursor or retained sorted
        // copy is needed. Keep each storage turn bounded so writes and retirement can interleave.
        let batchSize = CatalogRetentionLimits().pageSize
        var entities: [String: CatalogTrackMetadata] = [:]
        for offset in stride(from: 0, to: uris.count, by: batchSize) {
            let tracks: [String: CatalogTrack]
            do {
                tracks = try await storage.tracks(
                    for: Array(uris[offset..<min(uris.count, offset + batchSize)]), scope: storage.scope)
            } catch {
                try validate(stamp)
                throw CatalogEntityQueryFailure.unavailable
            }
            _ = try entityReadURIs(change, stamp: stamp, writeRevision: writeRevision)
            for (requestedURI, track) in tracks {
                entities[requestedURI] = CatalogTrackMetadata(track: track, requestedURI: requestedURI)
            }
        }
        return entities
    }

    private func entityReadURIs(
        _ change: CatalogEntityChange, stamp: UInt64, writeRevision: UInt64
    ) throws -> Set<String> {
        try validate(stamp)
        guard change.token.accountLifetime == accountLifetime else { throw CatalogEntityQueryFailure.retired }
        // One fence spans the complete read, including unrelated and no-op writes. Storage may
        // commit before this actor receives the change set; retry only after all writes drain.
        let consistency: CatalogEntityObservations.ReadConsistency =
            cacheWritesInFlight > 0 ? .writesPending : cacheRevision != writeRevision ? .crossedWrite : .stable
        return try entityObservations.pendingURIs(for: change, consistency: consistency)
    }

    package func acknowledgeCatalogEntities(_ token: CatalogEntitySubscriptionToken, revision: UInt64) async {
        guard active, token.accountLifetime == accountLifetime else { return }
        entityObservations.acknowledge(token, revision: revision)
    }

    package func unsubscribeCatalogEntities(_ token: CatalogEntitySubscriptionToken) async {
        guard active, token.accountLifetime == accountLifetime else { return }
        entityObservations.unsubscribe(token)
    }

    private func disableEntityQueries() {
        // A failed/rejected refresh still returns fresh live rows. Initial cache hydration must
        // not replace them with older metadata. An unrelated successful write cannot prove all
        // missed entities repaired, so observations remain unavailable for this account lifetime.
        entityQueryAvailability = .degraded
        entityObservations.finishAll()
    }

    private func cachedCollection(_ key: String, stamp: UInt64) async throws -> CatalogCollectionSnapshot? {
        guard accountVerified, let storage, cacheWritesInFlight == 0 else { return nil }
        let revision = cacheRevision
        do {
            let saved = try await storage.completeCollection(key: key, scope: storage.scope)
            try validate(stamp)
            // Storage supplies a coherent result. The provider additionally refuses a snapshot
            // whose read overlapped a live write, even when its clock sample and size match.
            guard cacheWritesInFlight == 0, cacheRevision == revision else { return nil }
            return saved
        } catch is CatalogStorageError {
            try validate(stamp)
            return nil
        }
    }

    private static func allowsCachedRead(after error: Error) -> Bool {
        switch error {
        case CatalogReadFailure.offline, CatalogReadFailure.timedOut, CatalogReadFailure.throttled:
            return true
        default: return false
        }
    }

    private static func withoutOwnership(_ item: CatalogItem?) -> CatalogItem? {
        item.map {
            CatalogItem(
                id: $0.id, uri: $0.uri, title: $0.title, subtitle: $0.subtitle,
                artworkURL: $0.artworkURL, kind: $0.kind
            )
        }
    }

}
