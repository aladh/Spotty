import AppKit
import SpottyDomain
import SwiftUI
import Testing
@testable import SpottyCore
@testable import SpottySessionRuntime

@Suite("Owned native track table")
@MainActor
struct NativeTrackTableChecks {
    @Test func selectionFollowsDuplicateOccurrenceAcrossSortAndMetadataUpdates() {
        let fixture = Fixture()
        let first = track(id: "first", title: "A")
        let second = track(id: "second", title: "B")
        fixture.state.selection = [second.id]
        fixture.update([first, second])
        #expect(fixture.container.table.selectedRowIndexes == IndexSet(integer: 1))
        fixture.update([second, first])
        #expect(fixture.container.table.selectedRowIndexes == IndexSet(integer: 0))
        #expect(fixture.state.selection == [second.id])
        fixture.update([track(id: "second", title: "Updated"), first])
        #expect(fixture.container.table.selectedRowIndexes == IndexSet(integer: 0))
        #expect(fixture.state.selection == [second.id])
        fixture.container.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: true)
        #expect(fixture.state.selection == [first.id, second.id])
    }

    @Test func keyboardRemovalUsesSelectedOccurrenceInsteadOfSharedTrackURI() {
        let fixture = Fixture()
        var removed: [String] = []
        fixture.actions = TrackPlaylistActions(
            editablePlaylists: [], canRemoveOccurrences: true,
            addToPlaylist: { _, _ in }, removeOccurrences: { removed = $0 }
        )
        let first = track(id: "first", title: "A", occurrenceUID: "server-first")
        let second = track(id: "second", title: "A", occurrenceUID: "server-second")
        fixture.update([first, second])
        fixture.container.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        #expect(fixture.container.table.deleteAction?() == true)
        #expect(removed == [second.id])
        fixture.actions = nil
        fixture.update([first, second])
        #expect(fixture.container.table.deleteAction?() == false)
    }

    @Test func nativeHeaderSortUsesDomainComparatorAndRetainsSelection() {
        let fixture = Fixture(variant: .catalog)
        let first = track(id: "first", title: "A")
        fixture.state.selection = [first.id]
        fixture.update([first])
        let column = fixture.container.table.tableColumns[0]
        fixture.coordinator.tableView(fixture.container.table, didClick: column)
        #expect(fixture.state.sortOrder == [KeyPathComparator(\TrackTableRow.title)])
        fixture.coordinator.tableView(fixture.container.table, didClick: column)
        #expect(fixture.state.sortOrder == [KeyPathComparator(\TrackTableRow.title, order: .reverse)])
        #expect(fixture.state.selection == [first.id])
    }

    @Test func ownedScrollOffsetRestoresAndClampsWithoutReplacingTheTable() {
        let fixture = Fixture()
        fixture.state.scrollOffset = 560
        fixture.update((0..<80).map { track(id: "occurrence-\($0)", title: "Track \($0)") })
        #expect(abs(fixture.container.scrollView.contentView.bounds.minY - 560) < 1)
        let table = fixture.container.table
        fixture.update((0..<80).map { track(id: "occurrence-\($0)", title: "Updated \($0)") })
        #expect(fixture.container.table === table)
        #expect(abs(fixture.container.scrollView.contentView.bounds.minY - 560) < 1)
        fixture.update([])
        #expect(fixture.container.scrollView.contentView.bounds.minY == 0)
    }

    @Test func keyboardRevealKeepsSelectionBelowTheCompactPlaylistHeader() {
        let fixture = Fixture()
        fixture.hero = AnyView(Color.clear.frame(height: 300))
        fixture.compact = AnyView(Color.clear.frame(height: 64))
        fixture.state.scrollOffset = 560
        fixture.update((0..<80).map { track(id: "occurrence-\($0)", title: "Track \($0)") })
        fixture.container.table.scrollRowToVisible(5)
        let rowTop = fixture.container.table.frame.minY + fixture.container.table.rect(ofRow: 5).minY
        let expected = rowTop - 100  // 64-point compact hero plus 36-point column header.
        #expect(abs(fixture.container.scrollView.contentView.bounds.minY - expected) < 1)
    }

    @Test func resizedColumnsExpandTheOwnedScrollDocument() throws {
        let fixture = Fixture(variant: .catalog)
        fixture.container.frame.size.width = 400
        fixture.update([track(id: "first", title: "A")])
        for (column, width) in zip(fixture.container.table.tableColumns, [264.0, 160.0, 170.0]) {
            column.width = width
        }
        fixture.container.didResizeColumns()
        fixture.container.layoutSubtreeIfNeeded()
        let document = try #require(fixture.container.scrollView.documentView)
        let columnWidth = fixture.container.table.tableColumns.reduce(0) { $0 + $1.width }
        #expect(document.frame.width >= columnWidth + 16)
    }

    private func track(id: String, title: String, occurrenceUID: String? = nil) -> CatalogTrack {
        CatalogTrack(
            id: id, uri: "spotify:track:shared", title: title, artist: "Artist", album: "Album",
            duration: 180, artworkURL: nil, addedAt: nil, occurrenceUID: occurrenceUID
        )
    }

    @MainActor
    private final class Fixture {
        let state = CatalogRouteInteractionState()
        let variant: TrackTableVariant
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make())
        let metadata = CatalogMetadataRepository(
            attributesProvider: HarnessTrackAttributes(),
            session: CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        )
        let container: NativeTrackTableContainer
        var coordinator: NativeTrackTable.Coordinator!
        var actions: TrackPlaylistActions?
        var hero: AnyView?
        var compact: AnyView?

        init(variant: TrackTableVariant = .playlist) {
            self.variant = variant
            container = NativeTrackTableContainer(variant: variant)
            container.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
            coordinator = NativeTrackTable.Coordinator(content([]))
            coordinator.attach(to: container)
        }

        func update(_ tracks: [CatalogTrack]) {
            coordinator.update(content(tracks), in: container)
        }

        private func content(_ tracks: [CatalogTrack]) -> NativeTrackTable {
            NativeTrackTable(
                rows: TrackTableDisplayCache(CatalogTrackCollection(tracks: tracks)).rows,
                variant: variant, playback: CatalogPlaybackAccess(player: player), metadata: metadata,
                searchQuery: "",
                selection: Binding(get: { [state] in state.selection }, set: { [state] in state.selection = $0 }),
                sortOrder: Binding(get: { [state] in state.sortOrder }, set: { [state] in state.sortOrder = $0 }),
                scrollOffset: Binding(
                    get: { [state] in state.scrollOffset }, set: { [state] in state.scrollOffset = $0 }),
                playlistActions: actions, onSelect: nil, playlistHeader: hero, compactPlaylistHeader: compact
            )
        }
    }
}
