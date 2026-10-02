@testable import SpottyRuntimeTestSupport
import SpottyTestSupport
import SpottyDomain
import SpottyRuntimeContracts
import Testing
@testable import SpottyCore

@MainActor
struct CatalogReadLifetimeTests {
    @Test func cancellingTheOriginalDetailCallerLeavesItsJoinedReadLoading() async throws {
        let responses = HarnessResponseGate<CatalogAlbumSnapshot>(cancellation: .ignored)
        defer { responses.close() }
        let provider = HarnessCatalog()
        provider.onAlbum = { _ in try await responses.wait() }
        let session = CatalogSessionAvailability(isAvailable: true)
        let store = AlbumDetailStore(
            provider: provider, metadata: CatalogMetadataRepository(session: session), session: session,
            clock: HarnessClock.sticky())
        let completed = HarnessCounters()
        let selected = item("album", kind: .album)
        let original = Task.immediate {
            defer { completed.record("original") }
            await store.load(selected)
        }
        defer { original.cancel() }
        try await requireEventually { responses.waiterCount == 1 }
        let joined = Task.immediate {
            defer { completed.record("joined") }
            await store.load(selected)
        }
        defer { joined.cancel() }
        original.cancel()

        try await requireEventually(
            description: "the cancelled detail caller settles while the shared read remains parked"
        ) {
            completed.count("original") == 1
        }
        #expect(store.isLoading)
        #expect(completed.count("joined") == 0)
        #expect(provider.albumRequestCount == 1)
        responses.finish(
            CatalogAlbumSnapshot(tracks: [HarnessFixtures.track(uri: "spotify:track:current")], releaseDate: "2026"))
        await joined.value
        #expect(!store.isLoading && store.tracks.first?.uri == "spotify:track:current")
    }

    @Test func cancellingTheOriginalLibraryCallerLeavesItsJoinedReadLoading() async throws {
        let responses = HarnessResponseGate<[PlaylistLibraryNode]>(cancellation: .ignored)
        defer { responses.close() }
        let provider = HarnessCatalog()
        provider.onPlaylistLibrary = { try await responses.wait() }
        let session = CatalogSessionAvailability(isAvailable: true)
        let store = HomeLibraryStore(
            provider: provider, metadata: CatalogMetadataRepository(session: session), session: session)
        let completed = HarnessCounters()
        let original = Task.immediate {
            defer { completed.record("original") }
            await store.loadPlaylists()
        }
        defer { original.cancel() }
        try await requireEventually { responses.waiterCount == 1 }
        let joined = Task.immediate { await store.loadPlaylists() }
        defer { joined.cancel() }
        original.cancel()

        try await requireEventually { completed.count("original") == 1 }
        #expect(store.isLoading(.playlists))
        #expect(responses.waiterCount == 1 && responses.requestCount == 1)
        responses.finish([PlaylistLibraryNode(playlist: item("playlist", kind: .playlist))])
        await joined.value
        #expect(!store.isLoading(.playlists) && store.playlists.count == 1)
    }

    @Test(arguments: [false, true])
    func precancelledDetailLoadCannotReplaceALiveSelection(force: Bool) async throws {
        let responses = HarnessResponseGate<CatalogAlbumSnapshot>(cancellation: .ignored)
        defer { responses.close() }
        let provider = HarnessCatalog()
        provider.onAlbum = { _ in try await responses.wait() }
        let session = CatalogSessionAvailability(isAvailable: true)
        let store = AlbumDetailStore(
            provider: provider, metadata: CatalogMetadataRepository(session: session), session: session,
            clock: HarnessClock.sticky())
        let selected = item("current", kind: .album)
        let original = Task.immediate { await store.load(selected) }
        defer { original.cancel() }
        try await requireEventually { responses.waiterCount == 1 }
        let cancelled = Task { await store.load(force ? selected : item("replacement", kind: .album), force: force) }
        cancelled.cancel()
        await cancelled.value

        #expect(store.item?.uri == selected.uri)
        #expect(store.isLoading)
        #expect(provider.albumRequestCount == 1)
        responses.finish(
            CatalogAlbumSnapshot(tracks: [HarnessFixtures.track(uri: "spotify:track:current")], releaseDate: "2026"))
        await original.value
        #expect(store.tracks.first?.uri == "spotify:track:current")
    }

    @Test func precancelledForcedLibraryLoadCannotSupersedeUsefulWork() async throws {
        let responses = HarnessResponseGate<[PlaylistLibraryNode]>(cancellation: .ignored)
        defer { responses.close() }
        let provider = HarnessCatalog()
        provider.onPlaylistLibrary = { try await responses.wait() }
        let session = CatalogSessionAvailability(isAvailable: true)
        let store = HomeLibraryStore(
            provider: provider, metadata: CatalogMetadataRepository(session: session), session: session)
        let original = Task.immediate { await store.loadPlaylists() }
        defer { original.cancel() }
        try await requireEventually { responses.waiterCount == 1 }
        let cancelled = Task { await store.loadPlaylists(force: true) }
        cancelled.cancel()
        await cancelled.value

        #expect(store.isLoading(.playlists))
        responses.finish([PlaylistLibraryNode(playlist: item("playlist", kind: .playlist))])
        await original.value
        #expect(store.playlists.count == 1)
        #expect(responses.requestCount == 1)
    }

    @Test func precancelledSearchKeepsCurrentRowsAndTheirLiveRefresh() async throws {
        let provider = HarnessCatalog()
        provider.onSearchTracks = { _, _ in [HarnessFixtures.track(uri: "spotify:track:saved")] }
        let session = CatalogSessionAvailability(isAvailable: true)
        let store = SearchStore(
            provider: provider, metadata: CatalogMetadataRepository(session: session), session: session,
            clock: HarnessClock.sticky())
        await store.search("current")
        let responses = HarnessResponseGate<[CatalogTrack]>(cancellation: .ignored)
        defer { responses.close() }
        provider.onSearchTracks = { _, _ in try await responses.wait() }
        let original = Task.immediate { await store.search("current") }
        defer { original.cancel() }
        try await requireEventually { responses.waiterCount == 1 }
        let cancelled = Task { await store.search("replacement") }
        cancelled.cancel()
        await cancelled.value

        #expect(store.tracks.first?.uri == "spotify:track:saved")
        #expect(store.isSearching)
        responses.finish([HarnessFixtures.track(uri: "spotify:track:current")])
        await original.value
        #expect(store.tracks.first?.uri == "spotify:track:current")
        #expect(provider.searchTrackRequestCount == 2)
    }

    @Test(arguments: [false, true])
    func precancelledSearchCannotDiscardAPendingDebounce(scheduled: Bool) async throws {
        let clock = HarnessClock.parked()
        defer { clock.releaseAll() }
        let provider = HarnessCatalog()
        provider.onSearchTracks = { _, _ in [HarnessFixtures.track(uri: "spotify:track:current")] }
        let session = CatalogSessionAvailability(isAvailable: true)
        let store = SearchStore(
            provider: provider, metadata: CatalogMetadataRepository(session: session), session: session, clock: clock)
        let pending = Task.immediate { await store.scheduleSearch("current") }
        defer { pending.cancel() }
        try await requireEventually { clock.waiterCount == 1 }
        let cancelled = Task {
            if scheduled { await store.scheduleSearch("replacement") } else { await store.search("replacement") }
        }
        cancelled.cancel()
        await cancelled.value

        #expect(clock.waiterCount == 1)
        clock.releaseNext()
        await pending.value
        #expect(store.tracks.first?.uri == "spotify:track:current")
        #expect(provider.searchTrackRequestCount == 1)
    }

    @Test func theLastDetailCallerSettlesLoadingAndRetiresAuthorityBeforeAResponse() async throws {
        let provider = HarnessCatalog()
        provider.onPlaylist = { _ in
            CatalogPlaylistSnapshot(description: "Kept", ownerURI: nil, tracks: [])
        }
        let session = CatalogSessionAvailability(isAvailable: true)
        let store = PlaylistStore(
            provider: provider, metadata: CatalogMetadataRepository(session: session), session: session)
        let selected = item("playlist", kind: .playlist)
        await store.load(selected)
        #expect(store.canEditLoadedContent)
        let responses = HarnessResponseGate<CatalogPlaylistSnapshot>(cancellation: .ignored)
        defer { responses.close() }
        provider.onPlaylist = { _ in try await responses.wait() }
        let completed = HarnessCounters()
        let refresh = Task.immediate {
            defer { completed.record("refresh") }
            await store.load(selected, force: true)
        }
        defer { refresh.cancel() }
        try await requireEventually { responses.waiterCount == 1 }
        refresh.cancel()
        try await requireEventually { completed.count("refresh") == 1 }
        #expect(!store.isLoading && !store.canEditLoadedContent && store.error == nil)
        #expect(store.description == "Kept")
        let replacement = Task.immediate {
            defer { completed.record("replacement") }
            await store.load(selected)
        }
        defer { replacement.cancel() }
        try await requireEventually { responses.waiterCount == 2 }
        #expect(store.isLoading)
        responses.finish(CatalogPlaylistSnapshot(description: "Retired", ownerURI: nil, tracks: []))
        responses.finish(CatalogPlaylistSnapshot(description: "Current", ownerURI: nil, tracks: []))
        try await requireEventually { completed.count("replacement") == 1 }
        #expect(store.description == "Current" && store.canEditLoadedContent && !store.isLoading)
    }

    @Test func aCancelledDetailReadReleasesItsCoordinatorWhileTheProviderRemainsParked() async throws {
        let responses = HarnessResponseGate<CatalogAlbumSnapshot>(cancellation: .ignored)
        defer { responses.close() }
        let provider = HarnessCatalog()
        provider.onAlbum = { _ in try await responses.wait() }
        let session = CatalogSessionAvailability(isAvailable: true)
        let completed = HarnessCounters()
        weak var released: CatalogDetailCoordinator?
        do {
            let detail = CatalogDetailCoordinator(
                kind: .album, provider: provider, session: session, clock: HarnessClock.sticky())
            released = detail
            let selected = item("album", kind: .album)
            let caller = Task.immediate {
                defer { completed.record("caller") }
                await detail.load(selected)
            }
            defer { caller.cancel() }
            try await requireEventually { responses.waiterCount == 1 }
            caller.cancel()
            try await requireEventually { completed.count("caller") == 1 }
            await caller.value
        }
        try await requireEventually { released == nil }
        #expect(responses.waiterCount == 1)
    }

    @Test func cancelledSearchReleasesItsStoreWhileASectionProviderRemainsParked() async throws {
        let responses = HarnessResponseGate<[CatalogTrack]>(cancellation: .ignored)
        defer { responses.close() }
        let provider = HarnessCatalog()
        provider.onSearchTracks = { _, _ in try await responses.wait() }
        let session = CatalogSessionAvailability(isAvailable: true)
        let completed = HarnessCounters()
        weak var released: SearchStore?
        do {
            let store = SearchStore(
                provider: provider, metadata: CatalogMetadataRepository(session: session), session: session,
                clock: HarnessClock.sticky())
            released = store
            let caller = Task.immediate {
                defer { completed.record("caller") }
                await store.search("query")
            }
            defer { caller.cancel() }
            try await requireEventually { responses.waiterCount == 1 }
            caller.cancel()
            try await requireEventually { completed.count("caller") == 1 }
            #expect(!store.isSearching)
            await caller.value
        }
        try await requireEventually { released == nil }
        #expect(responses.waiterCount == 1)
    }

    @Test func cancelledLibraryReadReleasesItsStoreWhileTheProviderRemainsParked() async throws {
        let responses = HarnessResponseGate<[PlaylistLibraryNode]>(cancellation: .ignored)
        defer { responses.close() }
        let provider = HarnessCatalog()
        provider.onPlaylistLibrary = { try await responses.wait() }
        let session = CatalogSessionAvailability(isAvailable: true)
        let completed = HarnessCounters()
        weak var released: HomeLibraryStore?
        do {
            let store = HomeLibraryStore(
                provider: provider, metadata: CatalogMetadataRepository(session: session), session: session)
            released = store
            let caller = Task.immediate {
                defer { completed.record("caller") }
                await store.loadPlaylists()
            }
            defer { caller.cancel() }
            try await requireEventually { responses.waiterCount == 1 }
            caller.cancel()
            try await requireEventually { completed.count("caller") == 1 }
            #expect(!store.isLoading)
            await caller.value
        }
        try await requireEventually { released == nil }
        #expect(responses.waiterCount == 1)
    }

    private func item(_ id: String, kind: CatalogItem.Kind) -> CatalogItem {
        CatalogItem(
            id: id, uri: "spotify:\(kind.rawValue.lowercased()):\(id)", title: id,
            subtitle: "", artworkURL: nil, kind: kind)
    }
}
