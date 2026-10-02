@testable import SpottyRuntimeTestSupport
import Foundation
import SpottyDomain
import SpottyRuntimeContracts
import SpottyTestSupport
import Testing
@testable import SpottyCore
@testable import SpottySessionRuntime

@Suite("Discography entity ownership")
@MainActor
struct DiscographyEntityTests {
    @Test
    func retainedAlbumsShareOneCompleteEntitySubscription() async throws {
        let provider = HarnessCatalog()
        let queries = HarnessCatalogQueries()
        provider.entityQueries = queries
        provider.onAlbum = { id in
            CatalogAlbumSnapshot(tracks: [HarnessFixtures.track(uri: "spotify:track:\(id)")], releaseDate: "2026")
        }
        let session = CatalogSessionAvailability(isAvailable: true)
        let metadata = CatalogMetadataRepository(session: session)
        let store = DiscographyStore(
            provider: provider, metadata: metadata, session: session, clock: HarnessClock.sticky())
        defer { store.reset() }
        store.prepare(artistURI: "spotify:artist:one")
        let count = CatalogEntityQueryLimits.maximumSubscriptions + 4
        for index in 0..<count {
            await store.load(release("\(index)"), artistURI: "spotify:artist:one")
        }
        let expected = Set((0..<count).map { "spotify:track:\($0)" })
        try await requireEventually { await queries.activeRequestedURIs == expected }
        try await requireEventually(description: "retained discography albums share one entity query") {
            await queries.activeQueryCount == 1
        }
        #expect(store.albums.count == count)
    }

    @Test
    func entityChangesReachTheAggregateMetadataAndRuntimeExport() async throws {
        let provider = HarnessCatalog()
        let queries = HarnessCatalogQueries()
        provider.entityQueries = queries
        let uri = "spotify:track:shared"
        provider.onAlbum = { _ in
            CatalogAlbumSnapshot(tracks: [HarnessFixtures.track(uri: uri, title: "Original")], releaseDate: "2026")
        }
        let session = CatalogSessionAvailability(isAvailable: true)
        let metadata = CatalogMetadataRepository(session: session)
        let store = DiscographyStore(
            provider: provider, metadata: metadata, session: session, clock: HarnessClock.sticky())
        defer { store.reset() }
        store.prepare(artistURI: "spotify:artist:one")
        let album = release("one")
        await store.load(album, artistURI: "spotify:artist:one")
        try await requireEventually { await queries.activeQueryCount == 1 }
        let before = metadata.browsingMetadata.revision

        await queries.publish([HarnessFixtures.track(uri: uri, title: "Updated")])
        try await requireEventually { await queries.acknowledgementCount == 1 }

        #expect(store.albums[album.uri]?.tracks.first?.title == "Updated")
        #expect(metadata.knownTrack(for: uri)?.title == "Updated")
        #expect(metadata.browsingMetadata.tracks[uri]?.title == "Updated")
        #expect(metadata.browsingMetadata.revision != before)
    }

    @Test
    func savedAlbumMetadataPublishesWhileItsLiveRefreshIsStillPending() async throws {
        let provider = HarnessCatalog()
        let uri = "spotify:track:saved"
        provider.onCachedAlbum = { _ in
            CatalogAlbumSnapshot(
                tracks: [HarnessFixtures.track(uri: uri, title: "Saved")], releaseDate: "2026",
                freshness: .cached(fetchedAt: HarnessDates.fixed))
        }
        let live = HarnessResponseGate<CatalogAlbumSnapshot>()
        defer { live.close() }
        provider.onAlbum = { _ in try await live.wait() }
        let session = CatalogSessionAvailability(isAvailable: true)
        let metadata = CatalogMetadataRepository(session: session)
        let store = DiscographyStore(
            provider: provider, metadata: metadata, session: session, clock: HarnessClock.sticky())
        defer { store.reset() }
        store.prepare(artistURI: "spotify:artist:one")
        let album = release("one")
        let load = Task { await store.load(album, artistURI: "spotify:artist:one") }
        defer { load.cancel() }
        try await requireEventually { live.waiterCount == 1 }

        #expect(store.albums[album.uri]?.tracks.first?.title == "Saved")
        #expect(store.albums[album.uri]?.isShowingCachedContent == true)
        #expect(metadata.knownTrack(for: uri)?.title == "Saved")
        #expect(metadata.browsingMetadata.tracks[uri]?.title == "Saved")

        live.finish(CatalogAlbumSnapshot(tracks: [HarnessFixtures.track(uri: uri, title: "Live")], releaseDate: "2026"))
        await load.value
        #expect(metadata.knownTrack(for: uri)?.title == "Live")
    }

    @Test
    func sharedEntitiesPreserveEveryOccurrenceFreshnessAndUnrelatedVersion() async throws {
        let provider = HarnessCatalog()
        let queries = HarnessCatalogQueries()
        provider.entityQueries = queries
        let shared = "spotify:track:shared"
        let rows = (0..<2).map { index in
            CatalogTrack(
                id: "display-\(index)", uri: shared, title: "Saved", artist: "Artist", album: "Album",
                duration: 100, artworkURL: nil, addedAt: HarnessDates.fixed.addingTimeInterval(Double(index)),
                occurrenceUID: "server-\(index)")
        }
        provider.onAlbum = { id in
            CatalogAlbumSnapshot(
                tracks: id == "other" ? [HarnessFixtures.track(uri: "spotify:track:other")] : rows,
                releaseDate: "2026", freshness: .cached(fetchedAt: HarnessDates.fixed))
        }
        let session = CatalogSessionAvailability(isAvailable: true)
        let metadata = CatalogMetadataRepository(session: session)
        let store = DiscographyStore(
            provider: provider, metadata: metadata, session: session, clock: HarnessClock.sticky())
        defer { store.reset() }
        store.prepare(artistURI: "spotify:artist:one")
        for id in ["first", "second", "other"] { await store.load(release(id), artistURI: "spotify:artist:one") }
        try await requireEventually { await queries.activeRequestedURIs == [shared, "spotify:track:other"] }
        let unrelatedVersion = store.albums[release("other").uri]?.trackCollection.version
        let subscriptions = await queries.subscriptionCount
        await queries.publish([HarnessFixtures.track(uri: shared, title: "Enriched")])
        try await requireEventually { await queries.acknowledgementCount == 1 }

        for id in ["first", "second"] {
            let child = try #require(store.albums[release(id).uri])
            #expect(child.tracks.map(\.title) == ["Enriched", "Enriched"])
            #expect(child.tracks.map(\.id) == rows.map(\.id))
            #expect(child.tracks.map(\.occurrenceUID) == rows.map(\.occurrenceUID))
            #expect(child.tracks.map(\.addedAt) == rows.map(\.addedAt))
            #expect(child.isShowingCachedContent)
            #expect(child.releaseDate == "2026")
        }
        #expect(store.albums[release("other").uri]?.trackCollection.version == unrelatedVersion)
        #expect(await queries.subscriptionCount == subscriptions, "enrichment does not replace the union query")
        #expect(metadata.browsingMetadata.tracks[shared]?.title == "Enriched")
    }

    @Test
    func directChildReplacementFencesAnAlreadyReturnedEntityReadWithTheSameURIs() async throws {
        let provider = HarnessCatalog()
        let queries = HarnessCatalogQueries()
        provider.entityQueries = queries
        let uri = "spotify:track:shared"
        provider.onAlbum = { _ in
            CatalogAlbumSnapshot(tracks: [HarnessFixtures.track(uri: uri, title: "Original")], releaseDate: "2026")
        }
        let session = CatalogSessionAvailability(isAvailable: true)
        let metadata = CatalogMetadataRepository(session: session)
        let store = DiscographyStore(
            provider: provider, metadata: metadata, session: session, clock: HarnessClock.sticky())
        defer { store.reset() }
        store.prepare(artistURI: "spotify:artist:one")
        let item = release("first")
        await store.load(item, artistURI: "spotify:artist:one")
        let child = try #require(store.albums[item.uri])
        try await requireEventually { await queries.activeQueryCount == 1 }
        let read = HarnessResponseGate<Void>(cancellation: .ignored)
        defer { read.close() }
        await queries.delayNextRead(until: read)
        await queries.publish([HarnessFixtures.track(uri: uri, title: "Old entity read")])
        try await requireEventually { read.waiterCount == 1 }
        // Match provider degradation: no new initial entity query can supersede this full result.
        await queries.finishStreams()
        await queries.failNextSubscription()
        provider.onAlbum = { _ in
            CatalogAlbumSnapshot(tracks: [HarnessFixtures.track(uri: uri, title: "Fresh")], releaseDate: "2026")
        }
        await child.load(item, force: true)
        try await requireEventually { await queries.subscriptionAttemptCount == 2 }
        #expect(metadata.knownTrack(for: uri)?.title == "Fresh")
        read.finish(())
        try await requireEventually { read.waiterCount == 0 }
        #expect(child.tracks.first?.title == "Fresh")
        #expect(metadata.browsingMetadata.tracks[uri]?.title == "Fresh")
        #expect(await queries.acknowledgementCount == 0)
    }

    @Test(arguments: [false, true])
    func retiredChildrenCannotRepublishAcrossArtistOrAccountReplacement(accountReplacement: Bool) async throws {
        let provider = HarnessCatalog()
        provider.onAlbum = { id in
            CatalogAlbumSnapshot(tracks: [HarnessFixtures.track(uri: "spotify:track:\(id)")], releaseDate: "2026")
        }
        let session = CatalogSessionAvailability(isAvailable: true)
        let metadata = CatalogMetadataRepository(session: session)
        let store = DiscographyStore(
            provider: provider, metadata: metadata, session: session, clock: HarnessClock.sticky())
        defer { store.reset() }
        let artist = "spotify:artist:one"
        store.prepare(artistURI: artist)
        await store.load(release("sibling"), artistURI: artist)
        let old = HarnessResponseGate<CatalogAlbumSnapshot>(cancellation: .ignored)
        defer { old.close() }
        provider.onAlbum = { _ in try await old.wait() }
        let item = release("first")
        let original = Task { await store.load(item, artistURI: artist) }
        defer { original.cancel() }
        try await requireEventually { old.waiterCount == 1 }
        let retired = try #require(store.albums[item.uri])
        if accountReplacement {
            session.update(accountEpoch: 2, isAvailable: true)
        } else {
            store.prepare(artistURI: "spotify:artist:two")
            store.prepare(artistURI: artist)
        }
        provider.onAlbum = { _ in
            CatalogAlbumSnapshot(tracks: [HarnessFixtures.track(uri: "spotify:track:fresh")], releaseDate: "2026")
        }
        await store.load(item, artistURI: artist)
        #expect(store.albums.count == 1)
        #expect(store.albums[item.uri] !== retired)
        old.finish(
            CatalogAlbumSnapshot(tracks: [HarnessFixtures.track(uri: "spotify:track:retired")], releaseDate: "2020"))
        await original.value
        // Retained external references may load again; their callbacks no longer own membership.
        await retired.load(item, force: true)
        #expect(store.albums[item.uri]?.tracks.map(\.uri) == ["spotify:track:fresh"])
        #expect(metadata.knownTrack(for: "spotify:track:sibling") == nil)
        #expect(metadata.knownTrack(for: "spotify:track:retired") == nil)
        #expect(metadata.knownTrack(for: "spotify:track:fresh") != nil)
    }

    @Test
    func evictionAndPrecancelledLoadsPreserveMembershipAndSourcePriority() async throws {
        let provider = HarnessCatalog()
        let queries = HarnessCatalogQueries()
        provider.entityQueries = queries
        let shared = "spotify:track:shared"
        provider.onAlbum = { id in
            CatalogAlbumSnapshot(
                tracks: [HarnessFixtures.track(uri: "spotify:track:\(id)"), HarnessFixtures.track(uri: shared)],
                releaseDate: "2026")
        }
        let session = CatalogSessionAvailability(isAvailable: true)
        let metadata = CatalogMetadataRepository(session: session)
        let store = DiscographyStore(
            provider: provider, metadata: metadata, session: session, clock: HarnessClock.sticky())
        defer { store.reset() }
        let artist = "spotify:artist:one"
        store.prepare(artistURI: artist)
        for index in 0..<20 { await store.load(release("\(index)"), artistURI: artist) }
        let expected = Set((0..<20).map { "spotify:track:\($0)" } + [shared])
        try await requireEventually { await queries.activeRequestedURIs == expected }
        let cancelledNew = Task { await store.load(release("cancelled"), artistURI: artist) }
        cancelledNew.cancel()
        await cancelledNew.value
        let cancelledTouch = Task { await store.load(release("0"), artistURI: artist) }
        cancelledTouch.cancel()
        await cancelledTouch.value
        #expect(provider.albumRequestCount == 20)
        #expect(store.albums.count == 20)
        #expect(await queries.activeRequestedURIs == expected)
        metadata.replaceTracks([HarnessFixtures.track(uri: shared, title: "Standalone album")], from: .album)
        await store.load(release("20"), artistURI: artist)
        try await requireEventually {
            await queries.activeRequestedURIs == Set((1...20).map { "spotify:track:\($0)" } + [shared])
        }
        #expect(store.albums[release("0").uri] == nil, "a cancelled touch must not reorder eviction")
        #expect(metadata.knownTrack(for: "spotify:track:0") == nil)
        await queries.publish([HarnessFixtures.track(uri: shared, title: "Enriched discography")])
        try await requireEventually { await queries.acknowledgementCount == 1 }
        #expect(metadata.knownTrack(for: shared)?.title == "Standalone album")
        metadata.replaceTracks([], from: .album)
        #expect(metadata.knownTrack(for: shared)?.title == "Enriched discography")
        store.reset()
        try await requireEventually { await queries.activeQueryCount == 0 }
        #expect(metadata.knownTrack(for: shared) == nil)
    }

    @Test(arguments: [false, true])
    func directChildClearingRemovesAggregateLabelsAndTheQuery(refused: Bool) async throws {
        let provider = HarnessCatalog()
        let queries = HarnessCatalogQueries()
        provider.entityQueries = queries
        let uri = "spotify:track:cleared"
        provider.onAlbum = { _ in
            CatalogAlbumSnapshot(tracks: [HarnessFixtures.track(uri: uri)], releaseDate: "2026")
        }
        let session = CatalogSessionAvailability(isAvailable: true)
        let metadata = CatalogMetadataRepository(session: session)
        let store = DiscographyStore(
            provider: provider, metadata: metadata, session: session, clock: HarnessClock.sticky())
        defer { store.reset() }
        store.prepare(artistURI: "spotify:artist:one")
        let item = release("first")
        await store.load(item, artistURI: "spotify:artist:one")
        try await requireEventually { await queries.activeQueryCount == 1 }
        let child = try #require(store.albums[item.uri])
        if refused {
            provider.onAlbum = { _ in throw CatalogReadFailure.sessionExpired }
            await child.load(item, force: true)
        } else {
            child.reset()
        }
        #expect(child.tracks.isEmpty)
        #expect(metadata.knownTrack(for: uri) == nil)
        try await requireEventually { await queries.activeQueryCount == 0 }
    }

    @Test
    func realProviderKeepsCapacityForOtherFeaturesAlongsideRetainedDiscography() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("discography-capacity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = HarnessCatalog()
        source.onProfile = { CatalogProfileSnapshot(name: "Fixture", uri: "spotify:user:fixture") }
        source.onAlbum = { id in
            CatalogAlbumSnapshot(tracks: [HarnessFixtures.track(uri: "spotify:track:\(id)")], releaseDate: "2026")
        }
        let provider = PersistentCatalogProvider(source: source, rootDirectory: root)
        await provider.activate(accountEpoch: 1)
        _ = try await provider.profile()
        let session = CatalogSessionAvailability(isAvailable: true)
        let metadata = CatalogMetadataRepository(session: session)
        let store = DiscographyStore(
            provider: provider, metadata: metadata, session: session, clock: HarnessClock.sticky())
        defer { store.reset() }
        // Other feature subscriptions leave exactly one slot for the complete discography.
        for index in 0..<(CatalogEntityQueryLimits.maximumSubscriptions - 1) {
            _ = try await provider.subscribeCatalogEntities(["spotify:track:other-\(index)"])
        }
        store.prepare(artistURI: "spotify:artist:one")
        for index in 0..<12 { await store.load(release("\(index)"), artistURI: "spotify:artist:one") }
        let changed = (0..<12).map { HarnessFixtures.track(uri: "spotify:track:\($0)", title: "Enriched") }
        source.onAlbum = { _ in CatalogAlbumSnapshot(tracks: changed, releaseDate: "2026") }
        _ = try await provider.album(id: "enrichment")
        try await requireEventually {
            store.albums.values.allSatisfy { $0.tracks.first?.title == "Enriched" }
        }
        #expect(store.albums.count == 12)
        #expect(metadata.browsingMetadata.tracks.count == 12)
        #expect(await provider.retire(accountEpoch: 1, purge: true))
    }

    private func release(_ id: String) -> CatalogItem {
        CatalogItem(
            id: id, uri: "spotify:album:\(id)", title: "Album \(id)", subtitle: "Artist", artworkURL: nil, kind: .album)
    }
}
