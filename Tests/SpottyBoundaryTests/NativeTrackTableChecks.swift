@testable import SpottyRuntimeTestSupport
import AppKit
import SpottyTestSupport
import SpottyDomain
import SpottyRuntimeContracts
import SwiftUI
import Testing
@testable import SpottyCore
@testable import SpottySessionRuntime

@Suite("Owned native track table")
@MainActor
struct NativeTrackTableChecks {
    @Test(arguments: [TrackTableVariant.catalog, .playlist, .album, .artist, .search])
    func metadataLabelsPreserveFormattingAndUpdateWithoutReplacingRows(variant: TrackTableVariant) throws {
        let fixture = Fixture(variant: variant)
        func row(duration: TimeInterval) -> CatalogTrack {
            CatalogTrack(
                id: "one", uri: "spotify:track:one", title: "One", artist: "Artist", album: "Album",
                duration: duration, artworkURL: nil, addedAt: nil)
        }
        fixture.update([row(duration: 180.6)])
        let table = fixture.container.table
        let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier("duration"))
        let duration = try #require(table.view(atColumn: column, row: 0, makeIfNecessary: true) as? NativeTrackTextCell)
        let roundsSeconds = variant == .playlist || variant == .search
        #expect(duration.label.stringValue == (roundsSeconds ? "3:01" : "3:00"))
        #expect(duration.label.alignment == (variant == .catalog ? .left : .center))
        #expect(!duration.label.acceptsFirstResponder)
        #expect(duration.label.accessibilityRole() == .staticText)
        #expect(duration.label.textColor == NSColor(SpottyPalette.dataText))

        fixture.state.selection = ["one"]
        fixture.update([row(duration: 241.6)])
        let updated = try #require(table.view(atColumn: column, row: 0, makeIfNecessary: true) as? NativeTrackTextCell)
        #expect(updated.label.stringValue == (roundsSeconds ? "4:02" : "4:01"))
        #expect(table.selectedRowIndexes == [0])
        #expect(updated.label.textColor == NSColor(SpottyPalette.dataText))
    }

    @Test func metadataReuseClearsMissingPlayCountsAndUnavailableStyling() throws {
        let fixture = Fixture(variant: .artist)
        let row = track(id: "one", title: "One")
        fixture.artistTracks = [row.uri: CatalogArtistPopularTrack(track: row, playCount: 12_345, isPlayable: false)]
        fixture.update([row])
        let table = fixture.container.table
        let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier("playCount"))
        let cell = try #require(table.view(atColumn: column, row: 0, makeIfNecessary: true) as? NativeTrackTextCell)
        #expect(cell.label.stringValue == 12_345.formatted())
        #expect(cell.label.accessibilityLabel() == "\(12_345.formatted()) plays")
        #expect(cell.label.alphaValue == 0.45)

        fixture.artistTracks = [:]
        fixture.update([row])
        #expect(table.view(atColumn: column, row: 0, makeIfNecessary: false) === cell)
        #expect(cell.label.stringValue.isEmpty)
        #expect(cell.label.accessibilityLabel() == nil)
        #expect(!cell.label.isAccessibilityElement())
        #expect(cell.label.alphaValue == 1)
    }

    @Test func retainedRowsReconcileSelectionAndRepairNativeDrift() {
        let fixture = Fixture()
        let rows = TrackTableDisplayCache(
            CatalogTrackCollection(tracks: [
                track(id: "first", title: "A"), track(id: "second", title: "B"),
            ])
        ).rows
        let table = fixture.container.table
        fixture.state.selection = ["first"]
        fixture.updateRows(rows)
        #expect(table.selectedRowIndexes == [0])
        fixture.state.selection = ["second"]
        fixture.updateRows(rows)
        #expect(table.selectedRowIndexes == [1])

        // A rejected native write leaves the requested value unchanged; it still needs repair.
        fixture.updateRows(rows, selection: .constant(["second"]))
        table.deselectAll(nil)
        #expect(table.selectedRowIndexes.isEmpty)
        fixture.updateRows(rows, selection: .constant(["second"]))
        #expect(table.selectedRowIndexes == [1])
        fixture.updateRows(Array(rows.reversed()), selection: .constant(["second"]))
        #expect(table.selectedRowIndexes == [0])
        fixture.updateRows([rows[0]], selection: .constant(["second"]))
        #expect(table.selectedRowIndexes.isEmpty)
        fixture.state.selection = []
        fixture.updateRows(rows)
        #expect(table.selectedRowIndexes.isEmpty)
    }

    @Test func retainedRowsRepairNativeRowCount() {
        let fixture = Fixture()
        let rows = TrackTableDisplayCache(
            CatalogTrackCollection(tracks: [
                track(id: "first", title: "A"), track(id: "second", title: "B"),
            ])
        ).rows
        fixture.state.selection = ["second"]
        fixture.updateRows(rows)
        let table = fixture.container.table
        table.dataSource = nil
        table.reloadData()
        #expect(table.numberOfRows == 0)
        table.dataSource = fixture.coordinator
        fixture.updateRows(rows)
        #expect(table.numberOfRows == 2)
        #expect(table.selectedRowIndexes == [1])
    }

    @Test func retainedAlbumRowsRefreshPlayCountOverrides() throws {
        let fixture = Fixture(variant: .album)
        let track = track(id: "one", title: "One")
        let rows = TrackTableDisplayCache(CatalogTrackCollection(tracks: [track])).rows
        fixture.artistTracks = [track.uri: CatalogArtistPopularTrack(track: track, playCount: 123, isPlayable: true)]
        fixture.playCounts = [track.uri: 456]
        fixture.updateRows(rows)
        let table = fixture.container.table
        let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier("playCount"))
        let cell = try #require(table.view(atColumn: column, row: 0, makeIfNecessary: true) as? NativeTrackTextCell)
        #expect(cell.label.stringValue == "456")
        fixture.playCounts = [:]
        fixture.updateRows(rows)
        #expect(table.view(atColumn: column, row: 0, makeIfNecessary: false) === cell)
        #expect(cell.label.stringValue == "123")
        fixture.artistTracks = [:]
        fixture.updateRows(rows)
        #expect(cell.label.stringValue.isEmpty)
        #expect(cell.label.accessibilityLabel() == nil)
    }

    @Test func removingAuxiliaryContentReleasesItsCapturedState() async throws {
        let fixture = Fixture(variant: .artist)
        var lifetime: NSObject? = NSObject()
        weak let released = lifetime
        fixture.hero = AnyView(RetainedContent(lifetime: lifetime!))
        fixture.compact = AnyView(RetainedContent(lifetime: lifetime!))
        fixture.footer = AnyView(RetainedContent(lifetime: lifetime!))
        lifetime = nil
        fixture.update([])
        #expect(released != nil)

        fixture.hero = nil
        fixture.compact = nil
        fixture.footer = nil
        fixture.update([])

        try await requireEventually(description: "removed headers and footer release their view state") {
            released == nil
        }
    }

    private struct RetainedContent: View {
        let lifetime: NSObject
        var body: some View { Color.clear.id(ObjectIdentifier(lifetime)).frame(height: 200) }
    }

    @Test(arguments: [TrackTableVariant.playlist, .album, .artist, .search])
    func selectionFollowsDuplicateOccurrenceAcrossSortAndMetadataUpdates(variant: TrackTableVariant) {
        let fixture = Fixture(variant: variant)
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
        let third = track(id: "third", title: "A", occurrenceUID: "server-third")
        fixture.update([first, second, third])
        fixture.container.table.selectRowIndexes(IndexSet([0, 2]), byExtendingSelection: false)
        fixture.update([third, second, first])
        #expect(fixture.container.table.deleteAction?() == true)
        #expect(removed == [third.id, first.id], "native row order preserves selected duplicate occurrences")
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

    @Test(arguments: [TrackTableVariant.playlist, .album, .artist, .search])
    func ownedScrollOffsetRestoresAndClampsWithoutReplacingTheTable(variant: TrackTableVariant) {
        let fixture = Fixture(variant: variant)
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

    @Test(arguments: [TrackTableVariant.playlist, .album, .artist, .search])
    func keyboardRevealKeepsSelectionBelowTheCompactDetailHeader(variant: TrackTableVariant) {
        let fixture = Fixture(variant: variant)
        fixture.hero = AnyView(Color.clear.frame(height: 300))
        fixture.compact = AnyView(Color.clear.frame(height: 64))
        fixture.state.scrollOffset = 560
        fixture.update((0..<80).map { track(id: "occurrence-\($0)", title: "Track \($0)") })
        fixture.container.table.scrollRowToVisible(5)
        let rowTop = fixture.container.table.frame.minY + fixture.container.table.rect(ofRow: 5).minY
        let expected = rowTop - (variant == .artist ? 64 : 100)
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

    @Test(arguments: [NSScroller.Style.overlay, .legacy])
    func albumResizesWithoutPushingDurationBeyondTheViewport(style: NSScroller.Style) throws {
        let fixture = Fixture(variant: .album)
        fixture.container.scrollView.scrollerStyle = style
        for width in [900.0, 400.0, 320.0, 700.0] {
            fixture.container.frame.size.width = width
            for rowCount in [12, 0, 1, 12] {
                fixture.update((0..<rowCount).map { track(id: "track-\($0)", title: "Track \($0)") })
                let document = try #require(fixture.container.scrollView.documentView)
                let viewport = fixture.container.scrollView.contentSize.width
                #expect(document.frame.width <= viewport)
                #expect(fixture.container.table.frame.maxX <= viewport - 24)
                #expect(
                    fixture.container.table.tableColumns.map(\.identifier.rawValue)
                        == ["index", "title", "playCount", "duration"])
                let plays = try #require(
                    fixture.container.table.tableColumns.first { $0.identifier.rawValue == "playCount" })
                #expect(plays.isHidden == (viewport - 48 < 520))
            }
        }
    }

    @Test func artistFooterSharesScrollingAndNarrowLayoutKeepsDurationVisible() throws {
        let fixture = Fixture(variant: .artist)
        fixture.hero = AnyView(Color.clear.frame(height: 400))
        fixture.footer = AnyView(Color.clear.frame(height: 600))
        fixture.compact = AnyView(Color.clear.frame(height: 64))
        for width in [900.0, 400.0, 320.0, 700.0] {
            fixture.container.frame.size.width = width
            fixture.update((0..<5).map { track(id: "track-\($0)", title: "Track \($0)") })
            let table = fixture.container.table
            let document = try #require(fixture.container.scrollView.documentView)
            #expect(table.frame.minY == 400)
            #expect(table.frame.height == 280)
            #expect(document.frame.height == 1280)
            #expect(table.frame.maxX <= fixture.container.scrollView.contentSize.width - 24)
            let plays = try #require(table.tableColumns.first { $0.identifier.rawValue == "playCount" })
            #expect(plays.isHidden == (width < 568))
        }
        fixture.state.scrollOffset = 800
        fixture.update((0..<5).map { track(id: "track-\($0)", title: "Updated") })
        #expect(fixture.container.scrollView.contentView.bounds.minY == 800)
        fixture.footer = AnyView(Color.clear.frame(height: 100))
        fixture.update([])
        #expect(fixture.container.scrollView.contentView.bounds.minY <= 100)
    }

    @Test(arguments: [NSScroller.Style.overlay, .legacy])
    func searchKeepsArtworkTitlesAndDurationWithinNarrowViewport(style: NSScroller.Style) throws {
        let fixture = Fixture(variant: .search)
        fixture.container.scrollView.scrollerStyle = style
        for width in [900.0, 400.0, 320.0, 700.0] {
            fixture.container.frame.size.width = width
            fixture.update((0..<50).map { track(id: "track-\($0)", title: "Track \($0)") })
            let viewport = fixture.container.scrollView.contentSize.width
            let table = fixture.container.table
            let document = try #require(fixture.container.scrollView.documentView)
            #expect(document.frame.width <= viewport)
            #expect(table.frame.maxX <= viewport - 24)
            #expect(table.tableColumns.map(\.identifier.rawValue) == ["index", "title", "album", "duration"])
            #expect(table.tableColumns[2].isHidden == (viewport - 48 < 520))
            #expect(table.tableColumns[1].width >= 140)
        }
    }

    @Test func playlistHeroUsesViewportBreakpointsWhileColumnsRemainScrollable() throws {
        let fixture = Fixture()
        fixture.hero = AnyView(
            ViewThatFits(in: .horizontal) {
                Color.clear.frame(width: 600, height: 100)
                Color.clear.frame(height: 300)
            })
        for width in [900.0, 400.0, 900.0] {
            fixture.container.frame.size.width = width
            fixture.update((0..<12).map { track(id: "track-\($0)", title: "Track \($0)") })
            #expect(fixture.container.table.frame.minY == (width >= 600 ? 136 : 336))
            let document = try #require(fixture.container.scrollView.documentView)
            let hero = try #require(document.subviews.first { $0.frame.minY == 0 })
            #expect(hero.frame.width == fixture.container.scrollView.contentSize.width)
            if width < 600 {
                #expect(document.frame.width > width, "all track columns remain reachable")
                fixture.container.scrollView.contentView.scroll(to: NSPoint(x: 100, y: 0))
                #expect(hero.frame.minX == 100, "horizontal track scrolling keeps the hero in the viewport")
            }
        }
    }

    @Test func artistInitialHostingLayoutRestoresAgainstTheCompleteTrackCount() throws {
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make())
        let state = CatalogRouteInteractionState()
        state.scrollOffset = 500
        let tracks = (0..<10).map { track(id: "track-\($0)", title: "Track \($0)") }
        let host = NSHostingView(
            rootView: TrackTable(
                tracks: CatalogTrackCollection(tracks: tracks), playback: CatalogPlaybackAccess(player: player),
                variant: .artist,
                detailHeader: AnyView(Color.clear.frame(height: 400)),
                detailFooter: AnyView(Color.clear.frame(height: 300)), interactionState: state))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        host.layoutSubtreeIfNeeded()
        func table(in view: NSView) -> NativeTrackTableContainer? {
            if let table = view as? NativeTrackTableContainer { return table }
            return view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        let container = try #require(table(in: host))
        #expect(container.table.numberOfRows == 10)
        #expect(container.scrollView.contentView.bounds.minY == 500)
        #expect(state.scrollOffset == 500)
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
        let container: NativeTrackTableContainer
        var coordinator: NativeTrackTable.Coordinator!
        var actions: TrackPlaylistActions?
        var hero: AnyView?
        var compact: AnyView?
        var footer: AnyView?
        var artistTracks: [String: CatalogArtistPopularTrack] = [:]
        var playCounts: [String: Int64] = [:]

        init(variant: TrackTableVariant = .playlist) {
            self.variant = variant
            container = NativeTrackTableContainer(variant: variant)
            container.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
            coordinator = NativeTrackTable.Coordinator(content([]))
            coordinator.attach(to: container)
        }

        func update(_ tracks: [CatalogTrack]) {
            updateRows(TrackTableDisplayCache(CatalogTrackCollection(tracks: tracks)).rows)
        }

        func updateRows(_ rows: [TrackTableRow], selection: Binding<Set<CatalogTrack.ID>>? = nil) {
            coordinator.update(content(rows, selection: selection), in: container)
        }

        private func content(_ rows: [TrackTableRow], selection: Binding<Set<CatalogTrack.ID>>? = nil)
            -> NativeTrackTable
        {
            NativeTrackTable(
                rows: rows,
                variant: variant, playback: CatalogPlaybackAccess(player: player),
                searchQuery: "",
                selection: selection
                    ?? Binding(get: { [state] in state.selection }, set: { [state] in state.selection = $0 }),
                sortOrder: Binding(get: { [state] in state.sortOrder }, set: { [state] in state.sortOrder = $0 }),
                scrollOffset: Binding(
                    get: { [state] in state.scrollOffset }, set: { [state] in state.scrollOffset = $0 }),
                playlistActions: actions, onSelect: nil, detailHeader: hero, compactDetailHeader: compact,
                detailFooter: footer, artistTracks: artistTracks, playCounts: playCounts
            )
        }
    }
}
