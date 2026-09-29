@testable import SpottyRuntimeTestSupport
import SpottyTestSupport
import Foundation
import SpottyDomain
import SpottyRuntimeContracts
import Testing
@testable import SpottyCore

@Suite("Catalog Route Retention")
@MainActor
struct CatalogRouteRetentionTests {
    @Test(arguments: [false, true])
    func savedPlaylistAppearsBeforeRefreshIncludingEmptyResults(empty: Bool) async throws {
        let provider = HarnessCatalog()
        let gate = HarnessResponseGate<CatalogPlaylistSnapshot>(cancellation: .ignored)
        defer { gate.close() }
        let savedTracks = empty ? [] : [HarnessFixtures.track(uri: "spotify:track:saved")]
        provider.onCachedPlaylist = { _ in
            CatalogPlaylistSnapshot(
                description: "Saved", ownerURI: "spotify:user:historical", tracks: savedTracks,
                freshness: .cached(fetchedAt: HarnessDates.fixed))
        }
        provider.onPlaylist = { _ in try await gate.wait() }
        let session = CatalogSessionAvailability(isAvailable: true)
        let store = makePlaylistStore(provider, session: session)
        let selected = item("saved", kind: .playlist)
        let load = Task { await store.load(selected) }
        defer { load.cancel() }
        try await requireEventually { gate.waiterCount == 1 }
        #expect(store.isLoading)
        #expect(!store.isLoadingInitialContent)
        #expect(store.isShowingCachedContent)
        #expect(store.description == "Saved")
        #expect(store.tracks == savedTracks)
        #expect(store.ownerURI == nil)
        #expect(!store.canEditLoadedContent)
        let freshTracks = [HarnessFixtures.track(uri: "spotify:track:fresh")]
        gate.finish(
            CatalogPlaylistSnapshot(description: "Fresh", ownerURI: "spotify:user:owner", tracks: freshTracks))
        await load.value
        #expect(store.tracks == freshTracks)
        #expect(store.description == "Fresh")
        #expect(!store.isShowingCachedContent)
        #expect(!store.isLoading)
        #expect(store.canEditLoadedContent)
    }

    @Test(arguments: [false, true])
    func savedAlbumAppearsBeforeRefreshIncludingEmptyResults(empty: Bool) async throws {
        let provider = HarnessCatalog()
        let gate = HarnessResponseGate<CatalogAlbumSnapshot>(cancellation: .ignored)
        defer { gate.close() }
        let tracks = empty ? [] : [HarnessFixtures.track(uri: "spotify:track:saved")]
        let credits = [item("artist", kind: .artist)]
        provider.onCachedAlbum = { _ in
            CatalogAlbumSnapshot(
                tracks: tracks, releaseDate: "2025", freshness: .cached(fetchedAt: HarnessDates.fixed),
                playCounts: ["spotify:track:saved": 123], artists: credits)
        }
        provider.onAlbum = { _ in try await gate.wait() }
        let session = CatalogSessionAvailability(isAvailable: true)
        let store = AlbumDetailStore(
            provider: provider, metadata: CatalogMetadataRepository(session: session), session: session)
        let load = Task { await store.load(item("saved", kind: .album)) }
        defer { load.cancel() }
        try await requireEventually { gate.waiterCount == 1 }
        #expect(store.isLoading && !store.isLoadingInitialContent)
        #expect(store.isShowingCachedContent)
        #expect(store.tracks == tracks)
        #expect(store.releaseDate == "2025")
        #expect(store.playCounts == ["spotify:track:saved": 123])
        #expect(store.artists == credits)
        gate.finish(CatalogAlbumSnapshot(tracks: [], releaseDate: "2026"))
        await load.value
        #expect(store.tracks.isEmpty)
        #expect(store.releaseDate == "2026")
        #expect(store.playCounts.isEmpty && store.artists.isEmpty)
        #expect(!store.isShowingCachedContent && !store.isLoading)
    }

    @Test(arguments: ["route", "account", "cancel"])
    func lateSavedPlaylistCannotPublishAfterItsLifetimeEnds(boundary: String) async throws {
        let provider = HarnessCatalog()
        let gate = HarnessResponseGate<CatalogPlaylistSnapshot>(cancellation: .ignored)
        defer { gate.close() }
        provider.onCachedPlaylist = { _ in try? await gate.wait() }
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let store = makePlaylistStore(provider, session: session)
        let selected = item("saved", kind: .playlist)
        let load = Task { await store.load(selected) }
        defer { load.cancel() }
        try await requireEventually { gate.waiterCount == 1 }
        switch boundary {
        case "route": store.prepare(item("other", kind: .playlist))
        case "account":
            session.update(accountEpoch: 2, isAvailable: true)
            store.prepare(selected)
        default: load.cancel()
        }
        gate.finish(
            CatalogPlaylistSnapshot(
                description: "Retired", ownerURI: nil, tracks: [HarnessFixtures.track(uri: "spotify:track:retired")],
                freshness: .cached(fetchedAt: HarnessDates.fixed)))
        await load.value
        #expect(store.tracks.isEmpty && store.description.isEmpty)
        #expect(!store.isShowingCachedContent && !store.canEditLoadedContent)
        #expect(provider.playlistRequestCount == 0)
    }

    @Test(arguments: ["route", "account", "cancel"])
    func lateSavedAlbumCannotPublishAfterItsLifetimeEnds(boundary: String) async throws {
        let provider = HarnessCatalog()
        let gate = HarnessResponseGate<CatalogAlbumSnapshot>(cancellation: .ignored)
        defer { gate.close() }
        provider.onCachedAlbum = { _ in try? await gate.wait() }
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let store = AlbumDetailStore(
            provider: provider, metadata: CatalogMetadataRepository(session: session), session: session)
        let selected = item("saved", kind: .album)
        let load = Task { await store.load(selected) }
        defer { load.cancel() }
        try await requireEventually { gate.waiterCount == 1 }
        switch boundary {
        case "route": store.prepare(item("other", kind: .album))
        case "account":
            session.update(accountEpoch: 2, isAvailable: true)
            store.prepare(selected)
        default: load.cancel()
        }
        gate.finish(
            CatalogAlbumSnapshot(
                tracks: [HarnessFixtures.track(uri: "spotify:track:retired")], releaseDate: "Retired",
                freshness: .cached(fetchedAt: HarnessDates.fixed)))
        await load.value
        #expect(store.tracks.isEmpty && store.releaseDate.isEmpty)
        #expect(!store.isShowingCachedContent)
        #expect(provider.albumRequestCount == 0)
    }

    @Test(arguments: [CatalogReadFailure.offline, .timedOut, .throttled, .sessionExpired], [false, true])
    func refreshFailuresKeepSavedDetailsOnlyWhileAccountProofRemainsValid(
        failure: CatalogReadFailure, empty: Bool
    ) async throws {
        let provider = HarnessCatalog()
        let playlistGate = HarnessResponseGate<Bool>(cancellation: .ignored)
        defer { playlistGate.close() }
        let albumGate = HarnessResponseGate<Bool>(cancellation: .ignored)
        defer { albumGate.close() }
        let tracks = empty ? [] : [HarnessFixtures.track(uri: "spotify:track:saved")]
        provider.onCachedPlaylist = { _ in
            CatalogPlaylistSnapshot(
                description: "Saved", ownerURI: nil, tracks: tracks, freshness: .cached(fetchedAt: HarnessDates.fixed))
        }
        provider.onCachedAlbum = { _ in
            CatalogAlbumSnapshot(
                tracks: tracks, releaseDate: "Saved", freshness: .cached(fetchedAt: HarnessDates.fixed))
        }
        provider.onPlaylist = { _ in
            _ = try await playlistGate.wait(); throw failure
        }
        provider.onAlbum = { _ in
            _ = try await albumGate.wait(); throw failure
        }
        let session = CatalogSessionAvailability(isAvailable: true)
        let playlist = makePlaylistStore(provider, session: session)
        let album = AlbumDetailStore(
            provider: provider, metadata: CatalogMetadataRepository(session: session), session: session)
        let selectedPlaylist = item("saved", kind: .playlist)
        let selectedAlbum = item("saved", kind: .album)
        let playlistLoad = Task { await playlist.load(selectedPlaylist) }
        defer { playlistLoad.cancel() }
        let albumLoad = Task { await album.load(selectedAlbum) }
        defer { albumLoad.cancel() }
        try await requireEventually { playlistGate.waiterCount == 1 }
        try await requireEventually { albumGate.waiterCount == 1 }
        #expect(playlist.tracks == tracks && album.tracks == tracks)
        playlistGate.finish(true)
        albumGate.finish(true)
        await playlistLoad.value
        await albumLoad.value
        #expect(playlist.error != nil && album.error != nil)
        #expect(playlist.isShowingCachedContent == (failure != .sessionExpired))
        #expect(album.isShowingCachedContent == (failure != .sessionExpired))
        #expect(!playlist.isLoadingInitialContent && !album.isLoadingInitialContent)
        #expect(!playlist.canEditLoadedContent)
        #expect(playlist.tracks.isEmpty == (empty || failure == .sessionExpired))
        #expect(album.tracks.isEmpty == (empty || failure == .sessionExpired))
        playlist.prepare(item("other", kind: .playlist))
        album.prepare(item("other", kind: .album))
        playlist.prepare(selectedPlaylist)
        album.prepare(selectedAlbum)
        #expect(playlist.tracks.isEmpty == (empty || failure == .sessionExpired))
        #expect(album.tracks.isEmpty == (empty || failure == .sessionExpired))
        #expect(!playlist.canEditLoadedContent)
    }

    @Test func playlistRevisitRestoresContentBeforeAnyNewRequest() async throws {
        let provider = HarnessCatalog()
        provider.onPlaylist = { id in
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

    @Test func cachedRevisitRetiresAnUncooperativeDifferentRoute() async throws {
        let provider = HarnessCatalog()
        let gate = HarnessResponseGate<CatalogPlaylistSnapshot>(cancellation: .ignored)
        defer { gate.close() }
        let first = item("first", kind: .playlist)
        let second = item("second", kind: .playlist)
        let firstSnapshot = CatalogPlaylistSnapshot(
            description: "First", ownerURI: nil,
            tracks: [HarnessFixtures.track(uri: "spotify:track:first")])
        provider.onPlaylist = { id in
            if id == "second" { return try await gate.wait() }
            return firstSnapshot
        }
        let session = CatalogSessionAvailability(isAvailable: true)
        let store = makePlaylistStore(provider, session: session)
        await store.load(first)
        let stale = Task { await store.load(second) }
        defer { stale.cancel() }
        try await requireEventually { gate.waiterCount == 1 }
        store.prepare(first)
        await store.load(first)
        gate.finish(
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

    @Test func accountReplacementCannotRestoreOrPopulateRetiredRoutes() async throws {
        let provider = HarnessCatalog()
        let gate = HarnessResponseGate<CatalogPlaylistSnapshot>(cancellation: .ignored)
        defer { gate.close() }
        let first = item("first", kind: .playlist)
        let second = item("second", kind: .playlist)
        let old = CatalogPlaylistSnapshot(
            description: "Old account", ownerURI: "spotify:user:old",
            tracks: [HarnessFixtures.track(uri: "spotify:track:old")])
        provider.onPlaylist = { id in id == "second" ? try await gate.wait() : old }
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let store = makePlaylistStore(provider, session: session)
        await store.load(first)
        let stale = Task { await store.load(second) }
        defer { stale.cancel() }
        try await requireEventually { gate.waiterCount == 1 }
        session.update(accountEpoch: 2, isAvailable: true)
        store.prepare(first)
        #expect(store.tracks.isEmpty)
        #expect(store.description.isEmpty)
        #expect(store.ownerURI == nil)
        gate.finish(old)
        await stale.value
        #expect(store.tracks.isEmpty)
        store.prepare(second)
        #expect(store.tracks.isEmpty)
    }

    @Test(arguments: ArtistDetailStore.Content.allCases)
    func albumAndArtistRevisitsReuseCompletePayloads(content: ArtistDetailStore.Content) async throws {
        let provider = HarnessCatalog()
        provider.onAlbum = { id in
            CatalogAlbumSnapshot(
                tracks: [HarnessFixtures.track(uri: "spotify:track:\(id)")], releaseDate: id,
                playCounts: ["spotify:track:\(id)": 9_876_543_210], artists: [Self.item(id, kind: .artist)])
        }
        provider.onArtist = { id in CatalogArtistSnapshot(name: id, releases: [Self.item(id, kind: .album)]) }
        provider.onArtistDiscography = { id in
            CatalogArtistSnapshot(name: nil, releases: [Self.item(id, kind: .album)])
        }
        let session = CatalogSessionAvailability(isAvailable: true)
        let metadata = CatalogMetadataRepository(session: session)
        let album = AlbumDetailStore(provider: provider, metadata: metadata, session: session)
        let artist = ArtistDetailStore(provider: provider, session: session, content: content)
        await album.load(item("first", kind: .album))
        let firstVersion = album.trackCollection.version
        await album.load(item("second", kind: .album))
        album.prepare(item("first", kind: .album))
        #expect(album.releaseDate == "first")
        #expect(album.playCounts == ["spotify:track:first": 9_876_543_210])
        #expect(album.artists == [item("first", kind: .artist)])
        #expect(album.trackCollection.version == firstVersion)
        await album.load(item("first", kind: .album))
        #expect(provider.albumRequestCount == 2)
        album.prepare(item("unloaded", kind: .album))
        #expect(album.playCounts.isEmpty)
        #expect(album.artists.isEmpty)
        album.prepare(item("first", kind: .album))
        #expect(album.playCounts == ["spotify:track:first": 9_876_543_210])

        await artist.load(item("first", kind: .artist))
        await artist.load(item("second", kind: .artist))
        artist.prepare(item("first", kind: .artist))
        #expect(artist.releases.map(\.uri) == ["spotify:album:first"])
        #expect(artist.releases.first?.subtitle == "first")
        await artist.load(item("first", kind: .artist))
        #expect(provider.artistRequestCount == (content == .overview ? 2 : 0))
        #expect(provider.discographyRequestCount == (content == .discography ? 2 : 0))
        session.update(accountEpoch: 2, isAvailable: true)
        album.prepare(item("first", kind: .album))
        artist.prepare(item("first", kind: .artist))
        #expect(album.tracks.isEmpty)
        #expect(album.playCounts.isEmpty)
        #expect(artist.releases.isEmpty)
    }

    @Test(
        arguments: ArtistDetailStore.Content.allCases,
        [CatalogReadFailure.offline, .timedOut, .throttled, .sessionExpired])
    func artistFailuresRetainContentOnlyWhileSessionProofRemainsValid(
        content: ArtistDetailStore.Content, failure: CatalogReadFailure
    ) async throws {
        let provider = HarnessCatalog()
        let first = item("first", kind: .artist)
        let second = item("second", kind: .artist)
        let snapshot = CatalogArtistSnapshot(
            name: "Artist", releases: [item("release", kind: .album)],
            overview: CatalogArtistOverview(
                monthlyListeners: 123,
                popularTracks: [
                    CatalogArtistPopularTrack(
                        track: HarnessFixtures.track(uri: "spotify:track:popular"), playCount: 456)
                ], biography: "Biography"),
            releaseKinds: ["spotify:album:release": .album], releaseDates: ["spotify:album:release": "2026"])
        provider.onArtist = { _ in snapshot }
        provider.onArtistDiscography = { _ in snapshot }
        let session = CatalogSessionAvailability(isAvailable: true)
        let store = ArtistDetailStore(provider: provider, session: session, content: content)
        await store.load(first)
        await store.load(second)
        store.prepare(first)
        let originalVersion = store.popularTracks.version
        provider.onArtist = { _ in throw failure }
        provider.onArtistDiscography = { _ in throw failure }
        await store.load(first, force: true)
        #expect(store.item?.uri == first.uri)
        #expect(store.error == CatalogErrorPresentation.message(for: failure))
        #expect(!store.isLoading)
        let expired = failure == .sessionExpired
        #expect(store.isShowingCachedContent == !expired)
        #expect(store.releases.isEmpty == expired)
        #expect((store.overview == nil) == expired)
        #expect(store.popularTracks.tracks.isEmpty == expired)
        #expect(store.popularPreview.tracks.isEmpty == expired)
        #expect(store.artistTracks.isEmpty == expired)
        #expect(store.releaseKinds.isEmpty == expired)
        #expect(store.releaseDates.isEmpty == expired)
        if !expired { #expect(store.popularTracks.version == originalVersion) }
        store.prepare(second)
        #expect(store.releases.isEmpty == expired, "Credential refusal clears other retained routes too")
        store.prepare(first)
        #expect(store.releases.isEmpty == expired, "Navigation cannot resurrect the rejected route")
        #expect(store.isShowingCachedContent == !expired)
        provider.onArtist = { _ in snapshot }
        provider.onArtistDiscography = { _ in snapshot }
        await store.load(first)
        #expect(store.releases.count == 1 && store.overview != nil)
        #expect(store.error == nil && !store.isShowingCachedContent)
        #expect(content == .overview ? provider.artistRequestCount == 4 : provider.discographyRequestCount == 4)
    }

    @Test(arguments: ArtistDetailStore.Content.allCases)
    func expiredArtistSessionCannotBeRepopulatedByAnOlderRoute(content: ArtistDetailStore.Content) async throws {
        let provider = HarnessCatalog()
        let first = item("first", kind: .artist)
        let snapshot = CatalogArtistSnapshot(name: "Artist", releases: [item("release", kind: .album)])
        provider.onArtist = { _ in snapshot }
        provider.onArtistDiscography = { _ in snapshot }
        let session = CatalogSessionAvailability(isAvailable: true)
        let store = ArtistDetailStore(provider: provider, session: session, content: content)
        await store.load(first)
        let gate = HarnessResponseGate<CatalogArtistSnapshot>(cancellation: .ignored)
        defer { gate.close() }
        let response: @Sendable (String) async throws -> CatalogArtistSnapshot = { id in
            if id == "late" { return try await gate.wait() }
            throw CatalogReadFailure.sessionExpired
        }
        provider.onArtist = response
        provider.onArtistDiscography = response
        let late = Task { await store.load(item("late", kind: .artist)) }
        defer { late.cancel() }
        try await requireEventually { gate.waiterCount == 1 }
        store.prepare(first)
        await store.load(first, force: true)
        gate.finish(snapshot)
        await late.value
        #expect(store.item?.uri == first.uri)
        #expect(store.releases.isEmpty)
        #expect(store.error == CatalogErrorPresentation.message(for: CatalogReadFailure.sessionExpired))
        #expect(!store.isShowingCachedContent && !store.isLoading)
        store.prepare(item("late", kind: .artist))
        #expect(store.releases.isEmpty)
    }

    @Test func staleProviderPayloadKeepsFreshnessAndRetries() async throws {
        let provider = HarnessCatalog()
        let old = CatalogFreshness.cached(fetchedAt: HarnessDates.fixed)
        provider.onPlaylist = { _ in
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
        provider.onPlaylist = { _ in
            CatalogPlaylistSnapshot(description: "Live", ownerURI: "spotify:user:owner", tracks: [])
        }
        await store.load(selected)
        #expect(provider.playlistRequestCount == 2)
        #expect(store.freshness.isCurrent)
        #expect(!store.isShowingCachedContent)
        #expect(store.canEditLoadedContent)
        #expect(store.description == "Live")
    }

    @Test func failedRefreshRetainsUsefulRowsWithoutMakingTheRevisitFresh() async throws {
        let provider = HarnessCatalog()
        let selected = item("first", kind: .playlist)
        let snapshot = CatalogPlaylistSnapshot(
            description: "Original", ownerURI: "spotify:user:owner",
            tracks: [HarnessFixtures.track(uri: "spotify:track:first")])
        provider.onPlaylist = { _ in snapshot }
        let session = CatalogSessionAvailability(isAvailable: true)
        let store = makePlaylistStore(provider, session: session)
        await store.load(selected)
        provider.onPlaylist = { _ in throw HarnessFailure.unavailable }
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

    @Test func acceptedMutationInvalidatesRetainedContentEvenWhenRefreshIsCancelled() async throws {
        let provider = HarnessCatalog()
        let gate = HarnessResponseGate<CatalogPlaylistSnapshot>(cancellation: .ignored)
        defer { gate.close() }
        let selected = item("first", kind: .playlist)
        let snapshot = CatalogPlaylistSnapshot(
            description: "Original", ownerURI: "spotify:user:owner",
            tracks: [HarnessFixtures.track(uri: "spotify:track:first")])
        provider.onPlaylist = { _ in snapshot }
        let session = CatalogSessionAvailability(isAvailable: true)
        let store = makePlaylistStore(provider, session: session)
        await store.load(selected)
        #expect(store.canEditLoadedContent)
        store.invalidateRetainedPlaylist(selected.uri)
        #expect(!store.canEditLoadedContent)
        provider.onPlaylist = { _ in try await gate.wait() }
        let refresh = Task { await store.load(selected, force: true) }
        defer { refresh.cancel() }
        try await requireEventually { gate.waiterCount == 1 }
        refresh.cancel()
        gate.finish(snapshot)
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
        let metadata = CatalogMetadataRepository(session: session)
        return PlaylistStore(provider: provider, metadata: metadata, session: session)
    }

    private nonisolated static func item(_ id: String, kind: CatalogItem.Kind) -> CatalogItem {
        CatalogItem(
            id: id, uri: "spotify:\(kind.rawValue.lowercased()):\(id)", title: id,
            subtitle: "", artworkURL: nil, kind: kind)
    }

    private func item(_ id: String, kind: CatalogItem.Kind) -> CatalogItem { Self.item(id, kind: kind) }
}
