import AppKit
import Observation
import SpottyDomain
import SwiftUI
import Testing
@testable import SpottyCore
@testable import SpottySessionRuntime

@Suite("Library folder keyboard navigation")
@MainActor
struct SidebarFolderKeyboardChecks {
    @Test func nativeFolderSelectionAndReturnPreserveTheOpenPage() async throws {
        let fixture = Fixture()
        defer { fixture.window.contentView = nil }
        let table = try await fixture.table(rows: 2)
        try #require(table.canSelectRow?(0) == true, "Folders must be reachable through native selection")
        table.keyDown(with: try key(code: 125, characters: "\u{F701}"))
        #expect(table.selectedRowIndexes == IndexSet(integer: 0))
        #expect(fixture.model.selection == .destination(.home), "Focusing a folder must not invent a playlist route")

        table.keyDown(with: try key(code: 36, characters: "\r"))
        _ = try await fixture.table(rows: 4)
        #expect(table.selectedRowIndexes == IndexSet(integer: 0))
        #expect(fixture.model.selection == .destination(.home))

        table.keyDown(with: try key(code: 125, characters: "\u{F701}"))
        try await requireEventually { fixture.model.selection == .playlist(fixture.child.id) }
        table.keyDown(with: try key(code: 126, characters: "\u{F700}"))
        try await requireEventually { table.selectedRowIndexes == IndexSet(integer: 0) }
        #expect(fixture.model.selection == .playlist(fixture.child.id))
        table.keyDown(with: try key(code: 36, characters: "\r"))
        _ = try await fixture.table(rows: 2)
        #expect(table.selectedRowIndexes == IndexSet(integer: 0))
        #expect(fixture.model.selection == .playlist(fixture.child.id), "Collapsing its parent leaves the detail open")
        #expect(fixture.engine.operations.isEmpty, "Folder navigation cannot play")
        await fixture.player.shutdownForTermination()
    }

    @Test func folderFocusSurvivesRefreshButYieldsToNavigationAndAccountRetirement() async throws {
        let fixture = Fixture()
        defer { fixture.window.contentView = nil }
        let table = try await fixture.table(rows: 2)
        try #require(table.canSelectRow?(0) == true)
        table.keyDown(with: try key(code: 125, characters: "\u{F701}"))
        table.keyDown(with: try key(code: 36, characters: "\r"))
        _ = try await fixture.table(rows: 4)

        fixture.model.library = [fixture.sibling, fixture.folder]
        try await requireEventually { table.selectedRowIndexes == IndexSet(integer: 1) }
        #expect(fixture.model.selection == .destination(.home))
        fixture.model.selection = .playlist(fixture.sibling.id)
        try await requireEventually { table.selectedRowIndexes == IndexSet(integer: 0) }
        table.keyDown(with: try key(code: 125, characters: "\u{F701}"))
        try await requireEventually { table.selectedRowIndexes == IndexSet(integer: 1) }
        #expect(fixture.model.selection == .playlist(fixture.sibling.id))

        fixture.model.library = [fixture.sibling]
        _ = try await fixture.table(rows: 1)
        try await requireEventually { table.selectedRowIndexes == IndexSet(integer: 0) }
        fixture.model.library = [fixture.folder, fixture.sibling]
        _ = try await fixture.table(rows: 4)
        #expect(table.selectedRowIndexes == IndexSet(integer: 3), "A removed folder cannot regain old focus")
        table.keyDown(with: try key(code: 126, characters: "\u{F700}"))
        table.keyDown(with: try key(code: 126, characters: "\u{F700}"))
        table.keyDown(with: try key(code: 126, characters: "\u{F700}"))
        try await requireEventually { table.selectedRowIndexes == IndexSet(integer: 0) }

        fixture.player.withRuntime {
            $0.accountStore.advanceEpoch()
            _ = $0.send(.reset(session: .ready), source: .account)
        }
        fixture.model.selection = .destination(.home)
        _ = try await fixture.table(rows: 2)
        try await requireEventually { table.selectedRowIndexes.isEmpty }
        #expect(fixture.engine.operations.isEmpty)
        await fixture.player.shutdownForTermination()
    }

    private func key(code: UInt16, characters: String) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code))
    }

    @Observable
    @MainActor
    fileprivate final class Model {
        var library: [PlaylistLibraryNode] = []
        var selection: SidebarSelection? = .destination(.home)
    }

    private struct HostedSidebar: View {
        @Bindable var model: Model
        let player: PlaybackStore

        var body: some View {
            SidebarView(
                selection: $model.selection, library: model.library, playback: CatalogPlaybackAccess(player: player))
        }
    }

    @MainActor
    private final class Fixture {
        let model = Model()
        let engine = HarnessEngine()
        let player: PlaybackStore
        let child = Fixture.playlist("child")
        let sibling = Fixture.playlist("sibling")
        let folder: PlaylistLibraryNode
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 208, height: 400), styleMask: [.borderless],
            backing: .buffered, defer: false)
        let host: NSHostingView<HostedSidebar>

        init() {
            player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(engine: engine))
            folder = PlaylistLibraryNode(
                folderURI: "folder:fixture", title: "Folder", children: [child, Self.playlist("second-child")])
            model.library = [folder, sibling]
            host = NSHostingView(rootView: HostedSidebar(model: model, player: player))
            window.contentView = host
        }

        func table(rows: Int) async throws -> NativeTrackTableView {
            func list(in view: NSView) -> NativeOccurrenceScrollView? {
                if let list = view as? NativeOccurrenceScrollView { return list }
                return view.subviews.lazy.compactMap { list(in: $0) }.first
            }
            try await requireEventually {
                self.host.layoutSubtreeIfNeeded()
                return list(in: self.host)?.table.numberOfRows == rows
            }
            return try #require(list(in: host)).table
        }

        private static func playlist(_ id: String) -> PlaylistLibraryNode {
            PlaylistLibraryNode(
                playlist: CatalogItem(
                    id: id, uri: "spotify:playlist:\(id)", title: id, subtitle: "Fixture", artworkURL: nil,
                    kind: .playlist))
        }
    }
}
