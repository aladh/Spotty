import Foundation
import SpottyDomain
import SpottyRuntimeContracts
import Testing
@testable import SpottyCore

/// Cooperative barrier for the catalog harness override; it intentionally ignores cancellation
/// so checks prove that the store's lifetime gate rejects a provider that completes too late.
private actor RouteResponseGate {
    private var continuation: CheckedContinuation<CatalogPlaylistSnapshot, Never>?
    var isWaiting: Bool { continuation != nil }

    func wait() async -> CatalogPlaylistSnapshot {
        await withCheckedContinuation { continuation = $0 }
    }

    func finish(_ snapshot: CatalogPlaylistSnapshot) {
        continuation?.resume(returning: snapshot)
        continuation = nil
    }
}

@Suite("Catalog Route Retention")
@MainActor
struct CatalogRouteRetentionTests {
    @Test func playlistRevisitRestoresContentBeforeAnyNewRequest() async {
        let provider = HarnessCatalog()
        provider.onPlaylistSnapshot = { id in
            CatalogPlaylistSnapshot(
                description: "Description \(id)", ownerURI: "spotify:user:owner",
                tracks: [HarnessFixtures.track(uri: "spotify:track:\(id)")])
        }
        let session = CatalogSessionAvailability(isAvailable: true)
        let store = makePlaylistStore(provider, session: session)
        let first = item("first", kind: .playlist)
        let second = item("second", kind: .playlist)
        await store.load(first)
        let firstVersion = store.trackCollection.version
        await store.load(second)

        store.prepare(first)
        #expect(store.tracks.map(\.uri) == ["spotify:track:first"])
        #expect(store.trackCollection.version == firstVersion)
        #expect(store.description == "Description first")
        #expect(!store.isLoading)
        await store.load(first)
        #expect(provider.playlistRequestCount == 2)
    }

    @Test func cachedRevisitRetiresAnUncooperativeDifferentRoute() async {
        let provider = HarnessCatalog()
        let gate = RouteResponseGate()
        let first = item("first", kind: .playlist)
        let second = item("second", kind: .playlist)
        let firstSnapshot = CatalogPlaylistSnapshot(
            description: "First", ownerURI: nil,
            tracks: [HarnessFixtures.track(uri: "spotify:track:first")])
        provider.onPlaylistSnapshot = { id in
            if id == "second" { return await gate.wait() }
            return firstSnapshot
        }
        let session = CatalogSessionAvailability(isAvailable: true)
        let store = makePlaylistStore(provider, session: session)
        await store.load(first)
        let stale = Task { await store.load(second) }
        #expect(await waitUntil { await gate.isWaiting })
        store.prepare(first)
        await store.load(first)
        await gate.finish(
            CatalogPlaylistSnapshot(
                description: "Stale", ownerURI: nil,
                tracks: [HarnessFixtures.track(uri: "spotify:track:stale")]))
        await stale.value
        #expect(store.loadedURI == first.uri)
        #expect(store.description == "First")
        #expect(store.tracks == firstSnapshot.tracks)
        #expect(!store.isLoading)
        store.prepare(second)
        #expect(store.tracks.isEmpty, "a rejected response must not enter the retained cache")
    }

    @Test func accountReplacementCannotRestoreOrPopulateRetiredRoutes() async {
        let provider = HarnessCatalog()
        let gate = RouteResponseGate()
        let first = item("first", kind: .playlist)
        let second = item("second", kind: .playlist)
        let old = CatalogPlaylistSnapshot(
            description: "Old account", ownerURI: "spotify:user:old",
            tracks: [HarnessFixtures.track(uri: "spotify:track:old")])
        provider.onPlaylistSnapshot = { id in id == "second" ? await gate.wait() : old }
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let store = makePlaylistStore(provider, session: session)
        await store.load(first)
        let stale = Task { await store.load(second) }
        #expect(await waitUntil { await gate.isWaiting })
        session.update(accountEpoch: 2, isAvailable: true)
        store.prepare(first)
        #expect(store.tracks.isEmpty)
        #expect(store.description.isEmpty)
        #expect(store.ownerURI == nil)
        await gate.finish(old)
        await stale.value
        #expect(store.tracks.isEmpty)
        store.prepare(second)
        #expect(store.tracks.isEmpty)
    }

    @Test func albumAndArtistRevisitsReuseCompletePayloads() async {
        let provider = HarnessCatalog()
        provider.onAlbumSnapshot = { id in
            CatalogAlbumSnapshot(tracks: [HarnessFixtures.track(uri: "spotify:track:\(id)")], releaseDate: id)
        }
        provider.onArtistSnapshot = { id in CatalogArtistSnapshot(name: id, releases: []) }
        provider.onArtistDiscographySnapshot = { id in
            CatalogArtistSnapshot(name: nil, releases: [Self.item(id, kind: .album)])
        }
        let session = CatalogSessionAvailability(isAvailable: true)
        let metadata = CatalogMetadataRepository(attributesProvider: HarnessTrackAttributes(), session: session)
        let album = AlbumDetailStore(provider: provider, metadata: metadata, session: session)
        let artist = ArtistDetailStore(provider: provider, session: session)
        await album.load(item("first", kind: .album))
        let firstVersion = album.trackCollection.version
        await album.load(item("second", kind: .album))
        album.prepare(item("first", kind: .album))
        #expect(album.releaseDate == "first")
        #expect(album.trackCollection.version == firstVersion)
        await album.load(item("first", kind: .album))
        #expect(provider.albumRequestCount == 2)

        await artist.load(item("first", kind: .artist))
        await artist.load(item("second", kind: .artist))
        artist.prepare(item("first", kind: .artist))
        #expect(artist.releases.map(\.uri) == ["spotify:album:first"])
        #expect(artist.releases.first?.subtitle == "first")
        await artist.load(item("first", kind: .artist))
        #expect(provider.artistRequestCount == 2)
        #expect(provider.discographyRequestCount == 2)
        session.update(accountEpoch: 2, isAvailable: true)
        album.prepare(item("first", kind: .album))
        artist.prepare(item("first", kind: .artist))
        #expect(album.tracks.isEmpty)
        #expect(artist.releases.isEmpty)
    }

    @Test func staleProviderPayloadKeepsFreshnessAndRetries() async {
        let provider = HarnessCatalog()
        let old = CatalogFreshness.cached(fetchedAt: HarnessDates.fixed)
        provider.onPlaylistSnapshot = { _ in
            CatalogPlaylistSnapshot(description: "Saved", ownerURI: "spotify:user:owner", tracks: [], freshness: old)
        }
        let session = CatalogSessionAvailability(isAvailable: true)
        let store = makePlaylistStore(provider, session: session)
        let selected = item("saved", kind: .playlist)
        await store.load(selected)
        #expect(store.freshness == old)
        #expect(store.isShowingCachedContent)
        #expect(!store.canEditLoadedContent)
        store.prepare(item("other", kind: .playlist))
        store.prepare(selected)
        #expect(store.freshness == old)
        #expect(store.isShowingCachedContent)
        #expect(!store.canEditLoadedContent)
        provider.onPlaylistSnapshot = { _ in
            CatalogPlaylistSnapshot(description: "Live", ownerURI: "spotify:user:owner", tracks: [])
        }
        await store.load(selected)
        #expect(provider.playlistRequestCount == 2)
        #expect(store.freshness.isCurrent)
        #expect(!store.isShowingCachedContent)
        #expect(store.canEditLoadedContent)
        #expect(store.description == "Live")
    }

    @Test func failedRefreshRetainsUsefulRowsWithoutMakingTheRevisitFresh() async {
        let provider = HarnessCatalog()
        let selected = item("first", kind: .playlist)
        let snapshot = CatalogPlaylistSnapshot(
            description: "Original", ownerURI: "spotify:user:owner",
            tracks: [HarnessFixtures.track(uri: "spotify:track:first")])
        provider.onPlaylistSnapshot = { _ in snapshot }
        let session = CatalogSessionAvailability(isAvailable: true)
        let store = makePlaylistStore(provider, session: session)
        await store.load(selected)
        provider.onPlaylistSnapshot = { _ in throw HarnessFailure.unavailable }
        await store.load(selected, force: true)
        #expect(store.error != nil)
        store.prepare(item("other", kind: .playlist))
        store.prepare(selected)
        #expect(store.tracks == snapshot.tracks)
        #expect(store.isShowingCachedContent)
        #expect(!store.canEditLoadedContent)
        await store.load(selected)
        #expect(provider.playlistRequestCount == 3)
        #expect(store.isShowingCachedContent)
        #expect(!store.canEditLoadedContent)
    }

    @Test func acceptedMutationInvalidatesRetainedContentEvenWhenRefreshIsCancelled() async {
        let provider = HarnessCatalog()
        let gate = RouteResponseGate()
        let selected = item("first", kind: .playlist)
        let snapshot = CatalogPlaylistSnapshot(
            description: "Original", ownerURI: "spotify:user:owner",
            tracks: [HarnessFixtures.track(uri: "spotify:track:first")])
        provider.onPlaylistSnapshot = { _ in snapshot }
        let session = CatalogSessionAvailability(isAvailable: true)
        let store = makePlaylistStore(provider, session: session)
        await store.load(selected)
        #expect(store.canEditLoadedContent)
        store.invalidateRetainedPlaylist(selected.uri)
        #expect(!store.canEditLoadedContent)
        provider.onPlaylistSnapshot = { _ in await gate.wait() }
        let refresh = Task { await store.load(selected, force: true) }
        #expect(await waitUntil { await gate.isWaiting })
        refresh.cancel()
        await gate.finish(snapshot)
        await refresh.value
        #expect(store.tracks == snapshot.tracks)
        #expect(store.isShowingCachedContent)
        #expect(!store.canEditLoadedContent)
        store.prepare(item("other", kind: .playlist))
        store.prepare(selected)
        #expect(store.tracks.isEmpty, "a cancelled reconciliation cannot resurrect an invalidated route")
    }

    @Test func retainedCacheBoundsRowsAndRejectsRetiredSessionWrites() {
        let session = CatalogSessionAvailability(isAvailable: true)
        let cache = RetainedCatalogRoutes<String>(session: session, routeLimit: 2, costLimit: 3)
        let original = session.snapshot
        cache.store("first", for: "first", cost: 1, snapshot: original)
        cache.store("second", for: "second", cost: 1, snapshot: original)
        #expect(cache.entry(for: "first")?.value == "first")
        cache.store("third", for: "third", cost: 2, snapshot: original)
        #expect(cache.entry(for: "second") == nil)
        #expect(cache.entry(for: "first")?.value == "first")
        cache.store("huge", for: "huge", cost: 4, snapshot: original)
        #expect(cache.entry(for: "huge") == nil)
        session.update(accountEpoch: 2, isAvailable: true)
        cache.store("retired", for: "retired", cost: 1, snapshot: original)
        #expect(cache.entry(for: "retired") == nil)
        #expect(cache.entry(for: "first") == nil)
    }

    private func makePlaylistStore(_ provider: HarnessCatalog, session: CatalogSessionAvailability) -> PlaylistStore {
        let metadata = CatalogMetadataRepository(attributesProvider: HarnessTrackAttributes(), session: session)
        return PlaylistStore(provider: provider, metadata: metadata, session: session)
    }

    private nonisolated static func item(_ id: String, kind: CatalogItem.Kind) -> CatalogItem {
        CatalogItem(
            id: id, uri: "spotify:\(kind.rawValue.lowercased()):\(id)", title: id,
            subtitle: "", artworkURL: nil, kind: kind)
    }

    private func item(_ id: String, kind: CatalogItem.Kind) -> CatalogItem { Self.item(id, kind: kind) }
}
