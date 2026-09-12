import AppKit
import SpottyDomain
import SwiftUI
import Testing
@testable import SpottyCore

@Suite("Owned native sidebar")
@MainActor
struct NativeSidebarChecks {
    @Test func keyboardSelectionSkipsFoldersAndKeepsOnePlaylistSelected() throws {
        let first = playlist("first")
        let last = playlist("last")
        let folder = PlaylistLibraryNode(folderURI: "folder:fixture", title: "Folder", children: [])
        let fixture = Fixture()
        fixture.update([first, folder, last])
        fixture.scroll.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
                isARepeat: false, keyCode: 125
            ))
        fixture.scroll.table.keyDown(with: event)
        #expect(fixture.selection == [last.id])
        #expect(fixture.scroll.table.selectedRowIndexes == IndexSet(integer: 2))
        #expect(!fixture.scroll.table.allowsMultipleSelection)
        #expect(fixture.scroll.table.selectionHighlightStyle == .none)
    }

    @Test func selectedPlaylistSurvivesFolderCollapseExpansionAndLibraryReordering() {
        let child = playlist("child")
        let sibling = playlist("sibling")
        let folder = PlaylistLibraryNode(folderURI: "folder:fixture", title: "Folder", children: [child])
        let fixture = Fixture()
        fixture.selection = [child.id]
        fixture.update([folder, sibling], expanded: [folder.id])
        #expect(fixture.scroll.table.selectedRowIndexes == IndexSet(integer: 1))

        fixture.update([folder, sibling])
        #expect(fixture.scroll.table.selectedRowIndexes.isEmpty)
        #expect(fixture.selection == [child.id])

        fixture.update([sibling, folder], expanded: [folder.id])
        #expect(fixture.scroll.table.selectedRowIndexes == IndexSet(integer: 2))
        #expect(fixture.selection == [child.id])
    }

    @Test func initialContentAndLaterUpdatesRetainSelectionAndScroll() {
        let library = (0..<40).map { playlist("item-\($0)") }
        let fixture = Fixture(library: library, selection: [library[10].id])
        #expect(fixture.scroll.table.numberOfRows == library.count)
        #expect(fixture.scroll.table.selectedRowIndexes == IndexSet(integer: 10))
        let table = fixture.scroll.table
        fixture.scroll.contentView.scroll(to: NSPoint(x: 0, y: 640))

        fixture.update(library)
        #expect(fixture.scroll.table === table)
        #expect(abs(fixture.scroll.contentView.bounds.minY - 640) < 1)
        #expect(fixture.scroll.table.selectedRowIndexes == IndexSet(integer: 10))
    }

    private func playlist(_ id: String) -> PlaylistLibraryNode {
        PlaylistLibraryNode(
            playlist: CatalogItem(
                id: id, uri: "spotify:playlist:\(id)", title: id, subtitle: "Fixture", artworkURL: nil, kind: .playlist
            ))
    }

    @MainActor
    private final class Fixture {
        var selection: Set<String> = []
        let scroll = NativeOccurrenceScrollView(frame: NSRect(x: 0, y: 0, width: 208, height: 400))
        var coordinator: NativeOccurrenceList.Coordinator!

        init(library: [PlaylistLibraryNode] = [], selection: Set<String> = []) {
            self.selection = selection
            let initial = content(rows(library, expanded: []))
            coordinator = NativeOccurrenceList.Coordinator(initial)
            coordinator.attach(to: scroll)
            coordinator.update(initial, in: scroll)
        }

        func update(_ library: [PlaylistLibraryNode], expanded: Set<String> = []) {
            coordinator.update(content(rows(library, expanded: expanded)), in: scroll)
        }

        private func rows(_ library: [PlaylistLibraryNode], expanded: Set<String>) -> [NativeOccurrenceListRow] {
            PlaylistLibraryNode.visibleRows(library, expanded: expanded).map { row in
                NativeOccurrenceListRow(
                    id: row.id, height: 64, isSelectable: row.node.playlist != nil,
                    content: AnyView(Text(row.node.title))
                )
            }
        }

        private func content(_ rows: [NativeOccurrenceListRow]) -> NativeOccurrenceList {
            NativeOccurrenceList(
                rows: rows,
                selection: Binding(get: { [unowned self] in selection }, set: { [unowned self] in selection = $0 }),
                allowsMultipleSelection: false, drawsSelection: false, accessibilityLabel: "Playlists"
            )
        }
    }
}
