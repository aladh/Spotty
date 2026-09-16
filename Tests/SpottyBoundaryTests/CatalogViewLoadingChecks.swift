import AppKit
import SwiftUI
import Testing
import SpottyDomain
@testable import SpottyCore
@testable import SpottySessionRuntime

@Suite("Catalog view loading", .serialized)
@MainActor
struct CatalogViewLoadingTests {
    @Test(arguments: ["", "first"])
    func changingVisibleSearchCancelsOldDebounceAndLoadsTheNewQuery(initialQuery: String) async throws {
        let provider = HarnessCatalog()
        let queries = HarnessCounters()
        let responseClock = HarnessClock.parked()
        let result = HarnessFixtures.track(uri: "spotify:track:second", title: "Result")
        provider.onSearchTracks = { query, _ in
            queries.record(query)
            try await responseClock.sleep(seconds: 1)
            return [result]
        }
        let clock = HarnessClock.parked()
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(clock: clock, catalog: provider))
        player.withRuntime {
            $0.accountStore.publishPhase(.ready)
            _ = $0.send(.session(.ready), source: .account)
        }
        let navigation = CatalogNavigation()
        navigation.updateSelection(.destination(.search))
        navigation.searchText = initialQuery
        let host = NSHostingView(
            rootView: RootView(
                player: player, catalog: player.catalog, feedback: player.feedback, navigation: navigation))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil; clock.releaseAll(); responseClock.releaseAll() }
        host.layoutSubtreeIfNeeded()
        try await requireEventually { clock.waiterCount == 1 }
        #expect(provider.searchTrackRequestCount == 0)

        navigation.searchText = "second"
        host.layoutSubtreeIfNeeded()
        try await requireEventually { clock.requestedSleeps.count == 2 && clock.waiterCount == 1 }
        #expect(clock.requestedSleeps == [SearchStore.queryAdmissionDelay, SearchStore.queryAdmissionDelay])
        clock.releaseNext()
        try await requireEventually { provider.searchTrackRequestCount == 1 && responseClock.waiterCount == 1 }
        host.layoutSubtreeIfNeeded()
        responseClock.releaseNext()
        let completed = await waitUntil {
            provider.searchTrackRequestCount == 1 && !player.catalog.searchStore.isSearching
        }
        try #require(
            completed,
            "reads=\(provider.searchTrackRequestCount), searching=\(player.catalog.searchStore.isSearching), sleeps=\(clock.requestedSleeps), waiting=\(clock.waiterCount)"
        )
        #expect(queries.count("first") == 0)
        #expect(queries.count("second") == 1)
        #expect(player.catalog.searchStore.tracks.map(\.uri) == ["spotify:track:second"])
        await player.shutdownForTermination()
    }

    @Test(arguments: [SidebarDestination.albums, .artists, .liked], [false, true])
    func visibleLibraryLoadsWhenStartupCompletes(destination: SidebarDestination, initiallyReady: Bool) async throws {
        let provider = HarnessCatalog()
        provider.onLibraryAlbums = { [] }
        provider.onLibraryArtists = { [] }
        provider.onLibraryTracks = { [] }
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(catalog: provider))
        player.withRuntime {
            $0.accountStore.publishPhase(initiallyReady ? .ready : .connecting)
            _ = $0.send(.session(initiallyReady ? .ready : .connecting), source: .account)
        }
        try #require(player.isConnected == initiallyReady)
        try #require(player.catalogSession.isAvailable == initiallyReady)
        let epoch = player.accountEpoch
        let navigation = CatalogNavigation()
        navigation.updateSelection(.destination(destination))
        var appeared = false
        let host = NSHostingView(
            rootView:
                RootView(player: player, catalog: player.catalog, feedback: player.feedback, navigation: navigation)
                .onAppear { appeared = true })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        await expectEventually { appeared }
        #expect(appeared)
        if !initiallyReady {
            #expect(readCount(destination, provider) == 0)
            player.withRuntime {
                $0.accountStore.publishPhase(.ready)
                _ = $0.send(.session(.ready), source: .account)
            }
            try #require(player.isConnected && player.catalogSession.isAvailable)
            host.layoutSubtreeIfNeeded()
        }
        await expectEventually { readCount(destination, provider) == 1 }
        #expect(readCount(destination, provider) == 1)
        #expect(player.accountEpoch == epoch, "ordinary startup keeps the same account identity")
        #expect(navigation.selection == .destination(destination), "the visible route did not change")
        await player.shutdownForTermination()
    }

    private func readCount(_ destination: SidebarDestination, _ provider: HarnessCatalog) -> Int {
        switch destination {
        case .albums: provider.libraryAlbumRequestCount
        case .artists: provider.libraryArtistRequestCount
        case .liked: provider.libraryTrackRequestCount
        default: 0
        }
    }
}
