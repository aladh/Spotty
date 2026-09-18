import AppKit
import SwiftUI
import Testing
@testable import SpottyCore
@testable import SpottySessionRuntime

@Suite("Search refresh continuity")
@MainActor
struct SearchRefreshChecks {
    @Test func retryKeepsTheNativeSongsTableAndSelection() async throws {
        let provider = HarnessCatalog()
        let tracks = (0..<30).map { HarnessFixtures.track(uri: "spotify:track:\($0)", title: "Song \($0)") }
        provider.onSearchTracks = { _, _ in tracks }
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(catalog: provider))
        player.withRuntime {
            $0.accountStore.publishPhase(.ready)
            _ = $0.send(.session(.ready), source: .account)
        }
        await player.catalog.searchStore.search("Song")
        let interaction = SearchInteractionState()
        interaction.prepare(for: "Song")
        interaction.filter = .songs
        let host = NSHostingView(
            rootView: SearchView(
                store: player.catalog.searchStore, playback: CatalogPlaybackAccess(player: player),
                searchText: .constant("Song"), interaction: interaction, onSelect: { _ in },
                playlistActions: TrackPlaylistActions(
                    editablePlaylists: [], canRemoveOccurrences: false,
                    addToPlaylist: { _, _ in }, removeOccurrences: { _ in })))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func table(in view: NSView) -> NativeTrackTableView? {
            if let table = view as? NativeTrackTableView { return table }
            return view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        try await requireEventually {
            host.layoutSubtreeIfNeeded()
            return table(in: host)?.numberOfRows == tracks.count
        }
        let original = try #require(table(in: host))
        original.selectRowIndexes(IndexSet(integer: 8), byExtendingSelection: false)
        let response = HarnessClock.parked()
        provider.onSearchTracks = { _, _ in
            try await response.sleep(seconds: 1)
            throw HarnessFailure.unavailable
        }
        let retry = Task { await player.catalog.searchStore.search("Song") }
        defer { response.releaseAll() }
        try await requireEventually { response.waiterCount == 1 }
        host.layoutSubtreeIfNeeded()
        #expect(table(in: host) === original)
        #expect(original.numberOfRows == tracks.count)
        #expect(original.selectedRowIndexes == IndexSet(integer: 8))
        response.releaseNext()
        await retry.value
        host.layoutSubtreeIfNeeded()
        #expect(table(in: host) === original)
        #expect(original.numberOfRows == tracks.count)
        #expect(original.selectedRowIndexes == IndexSet(integer: 8))
        #expect(player.catalog.searchStore.errors[.tracks] != nil)
        await player.shutdownForTermination()
    }
}
