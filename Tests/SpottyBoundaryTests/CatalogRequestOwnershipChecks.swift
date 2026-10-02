@testable import SpottyRuntimeTestSupport
import SpottyTestSupport
import Testing
import SpottyDomain
import SpottyRuntimeContracts
@testable import SpottyCore

@MainActor
struct CatalogRequestOwnershipTests {
    @Test(arguments: [false, true])
    func invalidPlaylistAddressSettlesLoading(previouslyLoaded: Bool) async {
        let provider = HarnessCatalog()
        let session = CatalogSessionAvailability(isAvailable: true)
        let store = PlaylistStore(
            provider: provider, metadata: CatalogMetadataRepository(session: session), session: session)
        let item = CatalogItem(
            id: "invalid", uri: "spotify:playlist:", title: "Invalid address",
            subtitle: "", artworkURL: nil, kind: .playlist)
        if previouslyLoaded {
            let previous = CatalogItem(
                id: "previous", uri: "spotify:playlist:previous", title: "Previous",
                subtitle: "", artworkURL: nil, kind: .playlist)
            provider.onPlaylist = { _ in
                CatalogPlaylistSnapshot(
                    description: "", ownerURI: nil,
                    tracks: [HarnessFixtures.track(uri: "spotify:track:previous")],
                    freshness: .cached(fetchedAt: HarnessDates.fixed))
            }
            await store.load(previous)
            #expect(store.isShowingCachedContent)
            #expect(store.tracks.count == 1)
        }

        await store.load(item)

        #expect(!store.isLoading)
        #expect(store.error != nil)
        #expect(!store.isShowingCachedContent)
        #expect(store.tracks.isEmpty)
        #expect(store.loadedURI == item.uri)
        #expect(!store.canEditLoadedContent)
        #expect(provider.playlistRequestCount == (previouslyLoaded ? 1 : 0))
    }

    @Test func precancelledFeatureLoadsSettleTheirIndicatorsAndAllowRetry() async {
        let provider = HarnessCatalog()
        let session = CatalogSessionAvailability(isAvailable: true)
        let metadata = CatalogMetadataRepository(session: session)
        let home = HomeLibraryStore(provider: provider, metadata: metadata, session: session)
        let album = AlbumDetailStore(
            provider: provider, metadata: metadata, session: session, clock: HarnessClock.sticky())
        let artist = ArtistDetailStore(provider: provider, session: session, clock: HarnessClock.sticky())
        let playlist = PlaylistStore(provider: provider, metadata: metadata, session: session)
        let search = SearchStore(provider: provider, metadata: metadata, session: session, clock: HarnessClock.sticky())
        func item(_ kind: CatalogItem.Kind) -> CatalogItem {
            CatalogItem(
                id: "synthetic", uri: "spotify:\(kind.rawValue.lowercased()):synthetic", title: "Synthetic",
                subtitle: "", artworkURL: nil, kind: kind)
        }
        let load = {
            await home.loadHome()
            await home.loadPlaylists()
            await album.load(item(.album))
            await artist.load(item(.artist))
            await playlist.load(item(.playlist))
            await search.search("synthetic")
        }
        let cancelled = Task { await load() }
        cancelled.cancel()
        await cancelled.value

        #expect(home.loadingSections.isEmpty)
        #expect(!album.isLoading)
        #expect(!artist.isLoading)
        #expect(!playlist.isLoading)
        #expect(!search.isSearching)
        #expect(
            provider.homeRequestCount + provider.playlistLibraryRequestCount + provider.albumRequestCount
                + provider.artistRequestCount + provider.playlistRequestCount + provider.searchTrackRequestCount == 0)

        await load()
        #expect(!home.isLoading && !album.isLoading && !artist.isLoading && !playlist.isLoading && !search.isSearching)
        #expect(provider.homeRequestCount == 1)
        #expect(provider.albumRequestCount == 1)
        #expect(provider.artistRequestCount == 1)
        #expect(provider.playlistRequestCount == 1)
        #expect(provider.searchTrackRequestCount == 1)
    }

    @Test(arguments: [CatalogReadFlights<String>.Scope.singleSelection, .perKey])
    func completedReadsDoNotOwnContentFreshness(scope: CatalogReadFlights<String>.Scope) async {
        let session = CatalogSessionAvailability(isAvailable: true)
        let reads = CatalogReadFlights<String>(session: session, scope: scope)
        var calls = 0
        var starts = 0
        var settlements = 0
        for _ in 0..<2 {
            await reads.read("route", started: { _ in starts += 1 }, settled: { settlements += 1 }) { _ in
                calls += 1
            }
        }
        #expect(calls == 2 && starts == 2 && settlements == 2)
    }

    @Test func resetSettlesEveryReadBeforeItsProviderAndAllowsReplacement() async throws {
        let responses = HarnessResponseGate<Void>(cancellation: .ignored)
        defer { responses.close() }
        let session = CatalogSessionAvailability(isAvailable: true)
        let reads = CatalogReadFlights<String>(session: session, scope: .perKey)
        let completed = HarnessCounters()
        var settled: [String] = []
        var published: [String] = []
        func load(_ key: String) -> Task<Void, Never> {
            Task.immediate {
                defer { completed.record(key) }
                await reads.read(key, settled: { settled.append(key) }) { handle in
                    try? await responses.wait()
                    if reads.isCurrent(handle) { published.append(key) }
                }
            }
        }
        let first = load("first")
        let second = load("second")
        defer { first.cancel(); second.cancel() }
        try await requireEventually { responses.waiterCount == 2 }
        reads.reset()
        #expect(Set(settled) == ["first", "second"])
        try await requireEventually { completed.count("first") == 1 && completed.count("second") == 1 }
        let replacement = load("first")
        defer { replacement.cancel() }
        try await requireEventually { responses.waiterCount == 3 }
        responses.finish(())
        responses.finish(())
        responses.finish(())
        try await requireEventually { completed.count("first") == 2 }
        #expect(published == ["first"])
        #expect(settled.filter { $0 == "first" }.count == 2 && settled.filter { $0 == "second" }.count == 1)
    }

    @Test func finalConsumerCancellationImmediatelyRevokesReadPublication() async throws {
        let responses = HarnessResponseGate<Void>(cancellation: .ignored)
        defer { responses.close() }
        let session = CatalogSessionAvailability(isAvailable: true)
        let reads = CatalogReadFlights<String>(session: session)
        let completed = HarnessCounters()
        var handle: CatalogReadFlights<String>.Handle?
        var settled = false
        let caller = Task.immediate {
            defer { completed.record("caller") }
            await reads.read("route", started: { handle = $0 }, settled: { settled = true }) { _ in
                try? await responses.wait()
            }
        }
        defer { caller.cancel() }
        try await requireEventually { responses.waiterCount == 1 }
        let admitted = try #require(handle)
        #expect(reads.isCurrent(admitted))
        caller.cancel()
        #expect(!reads.isCurrent(admitted), "the cancellation handler revokes publication before a MainActor hop")
        try await requireEventually { completed.count("caller") == 1 }
        #expect(settled)
        #expect(responses.waiterCount == 1)
    }
}
