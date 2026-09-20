import Testing
import SpottyDomain
@testable import SpottyCore

@MainActor
struct CatalogRequestOwnershipTests {
    @Test(arguments: [false, true])
    func invalidPlaylistAddressSettlesLoading(cached: Bool) async {
        let provider = HarnessCatalog()
        let session = CatalogSessionAvailability(isAvailable: true)
        let store = PlaylistStore(
            provider: provider, metadata: CatalogMetadataRepository(session: session), session: session)
        let item = CatalogItem(
            id: "invalid", uri: "spotify:playlist:", title: "Invalid address",
            subtitle: "", artworkURL: nil, kind: .playlist)
        if cached { store.replaceLoadedPlaylist(uri: item.uri, tracks: []) }

        await store.load(item)

        #expect(!store.isLoading)
        #expect(store.error != nil)
        #expect(store.isShowingCachedContent == cached)
        #expect(!store.canEditLoadedContent)
        #expect(provider.playlistRequestCount == 0)
    }

    @Test func precancelledFeatureLoadsSettleTheirIndicatorsAndAllowRetry() async {
        let provider = HarnessCatalog()
        let session = CatalogSessionAvailability(isAvailable: true)
        let metadata = CatalogMetadataRepository(session: session)
        let home = HomeLibraryStore(provider: provider, metadata: metadata, session: session)
        let album = AlbumDetailStore(provider: provider, metadata: metadata, session: session)
        let artist = ArtistDetailStore(provider: provider, session: session)
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

    enum Retirement: CaseIterable, Sendable {
        case reset, superseded, accountChanged, disconnected, reconnected, abandoned
    }

    @Test(arguments: Retirement.allCases)
    func retiredAdmissionCannotStartWork(retirement: Retirement) async {
        let session = CatalogSessionAvailability(isAvailable: true)
        let flight = AccountScopedSingleFlight<String>(session: session)
        let handle = flight.begin("route")
        switch retirement {
        case .reset:
            flight.reset()
        case .superseded:
            flight.begin("replacement")
        case .accountChanged:
            session.update(accountEpoch: 2, isAvailable: true)
        case .disconnected:
            session.update(accountEpoch: 1, isAvailable: false)
        case .reconnected:
            session.update(accountEpoch: 1, isAvailable: false)
            session.update(accountEpoch: 1, isAvailable: true)
        case .abandoned:
            flight.abandonUnstarted(handle)
        }
        var calls = 0
        await flight.run(handle) { calls += 1 }
        #expect(calls == 0)
        #expect(!flight.isCurrent(handle))
    }

    @Test(arguments: [false, true])
    func duplicateOrStaleRegistrationCannotDisplaceALiveTask(stale: Bool) async {
        let session = CatalogSessionAvailability(isAvailable: true)
        let flight = AccountScopedSingleFlight<String>(session: session)
        let old = flight.begin("route")
        let current = stale ? flight.begin("route") : old
        let clock = HarnessClock.parked()
        var originalWasCancelled = false
        let original = Task {
            await flight.run(current) {
                try? await clock.sleep(seconds: 10)
                originalWasCancelled = Task.isCancelled
            }
        }
        #expect(await waitUntil { clock.waiterCount == 1 })
        var unexpectedCalls = 0
        await flight.run(old) { unexpectedCalls += 1 }
        flight.reset()
        clock.releaseAll()
        await original.value
        #expect(unexpectedCalls == 0)
        #expect(originalWasCancelled, "reset must still own and cancel the original task")
    }

    @Test func completedAdmissionCannotStartAgain() async {
        let session = CatalogSessionAvailability(isAvailable: true)
        let flight = AccountScopedSingleFlight<String>(session: session)
        let handle = flight.begin("route")
        var calls = 0
        await flight.run(handle) { calls += 1 }
        await flight.run(handle) { calls += 1 }
        #expect(calls == 1)
    }

    @Test(arguments: [SingleFlightScopePolicy.singleSelection, .perKey])
    func completedFlightsDoNotCacheFreshness(scope: SingleFlightScopePolicy) async {
        let session = CatalogSessionAvailability(isAvailable: true)
        let flight = AccountScopedSingleFlight<String>(session: session, scope: scope)
        var calls = 0
        for _ in 0..<2 {
            guard case let .start(handle) = flight.admit("route") else {
                Issue.record("A finished flight must allow a fresh read when its caller requests one")
                return
            }
            await flight.run(handle) { calls += 1 }
        }
        #expect(calls == 2)
    }

    @Test func cancellationBeforeRegistrationCannotStartWork() async {
        let session = CatalogSessionAvailability(isAvailable: true)
        let flight = AccountScopedSingleFlight<String>(session: session)
        let handle = flight.begin("route")
        var calls = 0
        let caller = Task { await flight.run(handle) { calls += 1 } }
        // MainActor has not yielded since creating the caller, so cancellation precedes run.
        caller.cancel()
        await caller.value
        #expect(calls == 0)
    }
}
