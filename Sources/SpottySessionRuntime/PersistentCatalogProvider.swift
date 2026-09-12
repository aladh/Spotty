import Foundation
import SpottyCatalogStorage
import SpottyDiagnostics
import SpottyDomain
import SpottyRuntimeContracts

package protocol CatalogCacheLifecycle: Sendable {
    func activate() async
    /// False means account content remains fenced but could not be removed from disk.
    func retire(purge: Bool) async -> Bool
}

/// Account-stamped gateway reads with an optional persistent browsing cache. A verified profile
/// binds the database to the current account; a stored selector never substitutes for that proof.
/// Writes and Connect ordering deliberately do not pass through this cache.
package actor PersistentCatalogProvider: CatalogProviding, CatalogCacheLifecycle, CatalogEntityQueryProviding {
    private let source: any CatalogProviding
    private let rootDirectory: URL
    private let clock: any PlaybackClock
    private var generation: UInt64 = 0
    private var active = false
    private var storage: PersistentCatalog?
    private var accountURI: String?
    private var cleanupFailed = false
    private var retirementInProgress = false
    private var accountMismatch = false
    private var cacheRevision: UInt64 = 0
    private var cacheWritesInFlight = 0
    private var accountLifetime = UUID()
    private enum EntityQueryAvailability { case unbound, available, degraded }
    private var entityQueryAvailability: EntityQueryAvailability = .unbound
    private var entitySubscriptions: [UUID: EntityObservation] = [:]

    private struct EntityObservation {
        let token: CatalogEntitySubscriptionToken
        let requestedURIs: Set<String>
        let continuation: AsyncStream<CatalogEntityChange>.Continuation
        var pendingURIs: Set<String>
        var revision: UInt64 = 0
        var retryAfterWrite = false

        var change: CatalogEntityChange {
            CatalogEntityChange(token: token, revision: revision, totalCount: pendingURIs.count)
        }
    }

    package init(
        source: any CatalogProviding,
        rootDirectory: URL,
        clock: any PlaybackClock = SystemPlaybackClock()
    ) {
        self.source = source
        self.rootDirectory = rootDirectory
        self.clock = clock
    }

    package func activate() async {
        guard !active, !cleanupFailed, !retirementInProgress, !accountMismatch else { return }
        generation &+= 1
        accountLifetime = UUID()
        entityQueryAvailability = .unbound
        active = true
    }

    package func retire(purge: Bool) async -> Bool {
        // A competing retirement cannot clear this owner's storage or reopen admission while
        // its disk operation is suspended. A false result keeps the caller's cleanup fence.
        guard !retirementInProgress else { return false }
        retirementInProgress = true
        defer { retirementInProgress = false }
        active = false
        generation &+= 1
        finishEntitySubscriptions()
        accountURI = nil
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
        let profile = try await source.profile()
        try validate(stamp)
        guard let uri = profile.uri, uri.hasPrefix("spotify:user:"), !uri.dropFirst(13).isEmpty else {
            if accountURI != nil {
                active = false
                generation &+= 1
                accountMismatch = true
                finishEntitySubscriptions()
                throw CatalogReadFailure.sessionExpired
            }
            return profile
        }
        if let accountURI, accountURI != uri {
            // A grant changed without its expected retirement. Refuse both accounts until the
            // runtime performs the normal boundary; never rebind live requests by convenience.
            active = false
            generation &+= 1
            accountMismatch = true
            finishEntitySubscriptions()
            throw CatalogReadFailure.sessionExpired
        }
        guard storage == nil else { return profile }
        accountURI = uri
        let database = PersistentCatalog(rootDirectory: rootDirectory, accountID: uri)
        storage = database
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
        do {
            let value = try await source.playlist(id: id)
            try validate(stamp)
            await persist(
                key: "spotify:playlist:\(id)", tracks: value.tracks,
                metadata: CatalogCollectionMetadata(
                    item: value.item, description: value.description, ownerURI: value.ownerURI
                ), stamp: stamp
            )
            try validate(stamp)
            return value
        } catch {
            try validate(stamp)
            guard Self.allowsCachedRead(after: error),
                let cached = try await cachedCollection("spotify:playlist:\(id)", stamp: stamp)
            else { throw error }
            return CatalogPlaylistSnapshot(
                description: cached.page.metadata.description,
                ownerURI: nil, tracks: cached.tracks,
                item: Self.withoutOwnership(cached.page.metadata.item),
                freshness: .cached(fetchedAt: cached.page.fetchedAt)
            )
        }
    }

    package func album(id: String) async throws -> CatalogAlbumSnapshot {
        let stamp = try admission()
        do {
            let value = try await source.album(id: id)
            try validate(stamp)
            await persist(
                key: "spotify:album:\(id)", tracks: value.tracks,
                metadata: CatalogCollectionMetadata(item: value.item, releaseDate: value.releaseDate),
                stamp: stamp
            )
            try validate(stamp)
            return value
        } catch {
            try validate(stamp)
            guard Self.allowsCachedRead(after: error),
                let cached = try await cachedCollection("spotify:album:\(id)", stamp: stamp)
            else { throw error }
            return CatalogAlbumSnapshot(
                tracks: cached.tracks, releaseDate: cached.page.metadata.releaseDate,
                item: cached.page.metadata.item, freshness: .cached(fetchedAt: cached.page.fetchedAt)
            )
        }
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
        try await read { try await $0.playlistLibrary() }
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
        let value = try await operation(source)
        try validate(stamp)
        return value
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

    private func persist(
        key: String, tracks: [CatalogTrack], metadata: CatalogCollectionMetadata, stamp: UInt64
    ) async {
        guard active, stamp == generation, let storage else { return }
        cacheRevision &+= 1
        cacheWritesInFlight += 1
        defer {
            cacheWritesInFlight -= 1
            if cacheWritesInFlight == 0 { retryEntityPagesAfterWrites() }
        }
        do {
            let changes = try await storage.replaceCollection(
                CatalogCollectionWrite(
                    key: key, occurrences: CatalogOccurrence.browsingRows(tracks),
                    completeness: .complete, fetchedAt: clock.now(), metadata: metadata
                ), scope: storage.scope
            )
            guard active, stamp == generation else { return }
            guard !changes.collectionWriteRejected else {
                disableEntityQueries()
                return
            }
            publishEntityChanges(changes.trackURIs)
        } catch {
            guard active, stamp == generation else { return }
            disableEntityQueries()
            SpottyLog.catalog.warning("Catalog result could not be retained")
        }
    }

    package func subscribeCatalogEntities(_ uris: Set<String>) async throws -> CatalogEntitySubscription {
        _ = try admission()
        guard entityQueryAvailability == .available, storage != nil, accountURI != nil else {
            throw CatalogEntityQueryFailure.unavailable
        }
        guard uris.count <= CatalogEntityQueryLimits.maximumRequestedURIs,
            uris.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 8_192 && !$0.contains("\0") })
        else { throw CatalogEntityQueryFailure.invalidRequest }
        guard entitySubscriptions.count < CatalogEntityQueryLimits.maximumSubscriptions else {
            throw CatalogEntityQueryFailure.capacity
        }
        let token = CatalogEntitySubscriptionToken(accountLifetime: accountLifetime)
        let (stream, continuation) = AsyncStream.makeStream(
            of: CatalogEntityChange.self, bufferingPolicy: .bufferingNewest(1)
        )
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribeCatalogEntities(token) }
        }
        let observation = EntityObservation(
            token: token, requestedURIs: uris, continuation: continuation, pendingURIs: uris
        )
        entitySubscriptions[token.id] = observation
        continuation.yield(observation.change)
        return CatalogEntitySubscription(token: token, updates: stream)
    }

    package func catalogEntityPage(
        _ token: CatalogEntitySubscriptionToken, revision: UInt64, offset: Int, limit: Int
    ) async throws -> CatalogEntityPage {
        let stamp = try admission()
        let observation = try entityObservation(token)
        guard observation.revision == revision else { throw CatalogEntityQueryFailure.superseded }
        guard offset >= 0, offset <= observation.pendingURIs.count,
            limit > 0, limit <= CatalogEntityQueryLimits.pageSize
        else { throw CatalogEntityQueryFailure.invalidRequest }
        guard let storage else { throw CatalogEntityQueryFailure.unavailable }
        // The storage actor may commit a transaction before this actor receives its change set.
        // Suspend consumers until the last pending writer has published, including no-op writes.
        guard cacheWritesInFlight == 0 else {
            entitySubscriptions[token.id]?.retryAfterWrite = true
            throw CatalogEntityQueryFailure.superseded
        }
        let writeRevision = cacheRevision
        let uris = observation.pendingURIs.sorted()
        let nextOffset = min(uris.count, offset + limit)
        let tracks: [String: CatalogTrack]
        do {
            tracks = try await storage.tracks(for: Array(uris[offset..<nextOffset]), scope: storage.scope)
        } catch {
            try validate(stamp)
            throw CatalogEntityQueryFailure.unavailable
        }
        try validate(stamp)
        let current = try entityObservation(token)
        guard current.revision == revision else { throw CatalogEntityQueryFailure.superseded }
        guard cacheWritesInFlight == 0, cacheRevision == writeRevision else {
            if cacheWritesInFlight == 0 {
                // A write completed during this read. Its entity change may be unrelated, so
                // explicitly retry this consumer without invalidating any other observation.
                current.continuation.yield(current.change)
            } else {
                entitySubscriptions[token.id]?.retryAfterWrite = true
            }
            throw CatalogEntityQueryFailure.superseded
        }
        return CatalogEntityPage(
            token: token, revision: revision, offset: offset, totalCount: uris.count,
            nextOffset: nextOffset,
            tracks: Dictionary(
                uniqueKeysWithValues: tracks.map { requestedURI, track in
                    (
                        requestedURI,
                        CatalogTrack(
                            id: requestedURI, uri: requestedURI, title: track.title, artist: track.artist,
                            album: track.album, duration: track.duration, artworkURL: track.artworkURL,
                            addedAt: nil, artists: track.artists, albumItem: track.albumItem
                        )
                    )
                })
        )
    }

    package func acknowledgeCatalogEntities(_ token: CatalogEntitySubscriptionToken, revision: UInt64) async {
        guard let observation = try? entityObservation(token), observation.revision == revision else { return }
        entitySubscriptions[token.id]?.pendingURIs.removeAll(keepingCapacity: false)
    }

    package func unsubscribeCatalogEntities(_ token: CatalogEntitySubscriptionToken) async {
        guard let observation = try? entityObservation(token) else { return }
        entitySubscriptions.removeValue(forKey: token.id)
        observation.continuation.finish()
    }

    private func entityObservation(_ token: CatalogEntitySubscriptionToken) throws -> EntityObservation {
        guard active, token.accountLifetime == accountLifetime,
            let observation = entitySubscriptions[token.id], observation.token == token
        else { throw CatalogEntityQueryFailure.retired }
        return observation
    }

    private func publishEntityChanges(_ changedURIs: Set<String>) {
        guard !changedURIs.isEmpty else { return }
        for id in Array(entitySubscriptions.keys) {
            guard var observation = entitySubscriptions[id] else { continue }
            let relevant = changedURIs.intersection(observation.requestedURIs)
            guard !relevant.isEmpty else { continue }
            observation.pendingURIs.formUnion(relevant)
            observation.revision &+= 1
            entitySubscriptions[id] = observation
            observation.continuation.yield(observation.change)
        }
    }

    private func retryEntityPagesAfterWrites() {
        for id in Array(entitySubscriptions.keys) {
            guard var observation = entitySubscriptions[id], observation.retryAfterWrite else { continue }
            observation.retryAfterWrite = false
            entitySubscriptions[id] = observation
            observation.continuation.yield(observation.change)
        }
    }

    private func disableEntityQueries() {
        // A failed/rejected refresh still returns fresh live rows. Initial cache hydration must
        // not replace them with older metadata. An unrelated successful write cannot prove all
        // missed entities repaired, so observations remain unavailable for this account lifetime.
        entityQueryAvailability = .degraded
        finishEntitySubscriptions()
    }

    private func finishEntitySubscriptions() {
        let observations = entitySubscriptions.values
        entitySubscriptions.removeAll(keepingCapacity: false)
        for observation in observations { observation.continuation.finish() }
    }

    private func cachedCollection(
        _ key: String, stamp: UInt64
    ) async throws -> (page: CatalogCollectionPage, tracks: [CatalogTrack])? {
        guard let storage, cacheWritesInFlight == 0 else { return nil }
        let revision = cacheRevision
        do {
            guard let first = try await storage.collection(key: key, scope: storage.scope),
                first.completeness == .complete
            else { return nil }
            try validate(stamp)
            guard cacheWritesInFlight == 0, cacheRevision == revision else { return nil }
            var tracks = first.occurrences.map(\.track)
            while tracks.count < first.totalCount {
                guard
                    let page = try await storage.collection(
                        key: key, offset: tracks.count, scope: storage.scope
                    ), page.fetchedAt == first.fetchedAt, page.totalCount == first.totalCount,
                    !page.occurrences.isEmpty
                else { return nil }
                try validate(stamp)
                // Equal clock samples and collection sizes are not a revision. A concurrent
                // refresh must not splice two accepted results into one cached response.
                guard cacheWritesInFlight == 0, cacheRevision == revision else { return nil }
                tracks.append(contentsOf: page.occurrences.map(\.track))
            }
            return (first, tracks)
        } catch is CatalogStorageError {
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
