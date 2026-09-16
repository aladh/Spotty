import AppKit
import SwiftUI
import Testing
@testable import SpottyCore
@testable import SpottyGateway
@testable import SpottySessionRuntime

@Suite("Startup connection presentation")
@MainActor
struct StartupConnectionChecks {
    @Test func reconnectKeepsTheExistingSearchTableAndSelection() async throws {
        let provider = HarnessCatalog()
        let track = try JSONDecoder().decode(
            PathfinderTrack.self,
            from: Data(
                #"{"uri":"spotify:track:search-result","name":"Search result","albumOfTrack":{"name":"Album"},"artists":{"items":[{"profile":{"name":"Artist"}}]},"duration":{"totalMilliseconds":1000}}"#
                    .utf8))
        provider.onSearchTracks = { _, _ in [track] }
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(catalog: provider))
        player.withRuntime {
            $0.accountStore.publishPhase(.ready)
            _ = $0.send(.session(.ready), source: .account)
        }
        await player.catalog.searchStore.search("Harbor")
        var observedRecovery = false
        func content() -> some View {
            SearchView(
                store: player.catalog.searchStore, playback: CatalogPlaybackAccess(player: player),
                searchText: .constant("Harbor"), onSelect: { _ in },
                playlistActions: TrackPlaylistActions(
                    editablePlaylists: [], canRemoveOccurrences: false, addToPlaylist: { _, _ in },
                    removeOccurrences: { _ in })
            ).onChange(of: player.phase) { _, phase in observedRecovery = phase == .recovering }
        }
        let host = NSHostingView(rootView: content())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func table(in view: NSView) -> NativeTrackTableView? {
            if let table = view as? NativeTrackTableView { return table }
            return view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        try await requireEventually {
            host.layoutSubtreeIfNeeded()
            return table(in: host)?.numberOfRows == 1
        }
        let original = try #require(table(in: host))
        original.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        player.withRuntime {
            $0.accountStore.publishPhase(.recovering)
            _ = $0.send(.session(.recovering), source: .account)
        }
        try #require(player.phase == .recovering)
        host.rootView = content()
        try await requireEventually {
            host.layoutSubtreeIfNeeded()
            return observedRecovery
        }
        #expect(!player.catalog.searchStore.isEmpty)
        #expect(table(in: host) === original)
        #expect(original.selectedRowIndexes == IndexSet(integer: 0))
        await player.shutdownForTermination()
    }

    @Test(arguments: [false, true])
    func startupWaitsForSavedLoginBeforeOfferingConnect(hasGrant: Bool) async throws {
        let account = HarnessAccount(hasGrant: hasGrant)
        account.parkGrantRead = true
        let engine = HarnessEngine()
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(engine: engine, account: account))
        defer { account.completeGrantRead() }
        #expect(player.phase == .connecting)
        #expect(CatalogPlaybackAccess(player: player).connectionLoadingLabel != nil)

        let restore = Task { await player.restore() }
        try await requireEventually { account.isGrantReadParked }
        #expect(player.phase == .connecting)
        #expect(engine.count(.initialize) == 0)
        #expect(account.authorizeCount == 0)

        account.completeGrantRead()
        await restore.value
        if hasGrant {
            #expect(engine.count(.initialize) == 1)
            #expect(player.phase == .connecting, "restoration still awaits the engine's ready observation")
            #expect(CatalogPlaybackAccess(player: player).connectionLoadingLabel != nil)
            player.withRuntime { _ = $0.send(.session(.ready), source: .account) }
            #expect(CatalogPlaybackAccess(player: player).connectionLoadingLabel == nil)
        } else {
            #expect(player.phase == .signedOut)
            #expect(CatalogPlaybackAccess(player: player).connectionLoadingLabel == nil)
        }
        await player.shutdownForTermination()
    }
}
