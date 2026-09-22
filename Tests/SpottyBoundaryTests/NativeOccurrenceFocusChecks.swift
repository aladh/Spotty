import AppKit
@testable import SpottyDomain
import SwiftUI
import Testing
@testable import SpottyCore

@Suite("Native occurrence focus continuity")
@MainActor
struct NativeOccurrenceFocusChecks {
    @Test(arguments: [false, true])
    func tabReachesSelectedArtworkInAMultirowListWithoutPointerHover(rapidEntry: Bool) async throws {
        let scroll = NativeOccurrenceScrollView(frame: NSRect(x: 0, y: 40, width: 280, height: 300))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 340), styleMask: [.borderless],
            backing: .buffered, defer: false)
        let root = NSView(frame: window.contentLayoutRect)
        root.addSubview(scroll)
        let nextField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 30))
        root.addSubview(nextField)
        window.contentView = root
        window.autorecalculatesKeyViewLoop = false
        window.recalculateKeyViewLoop()
        scroll.table.nextKeyView = nextField
        nextField.nextKeyView = scroll.table
        defer { window.contentView = nil }
        let probe = ArtworkFocusProbe()
        let rows = ["first", "second"].map { id in
            NativeOccurrenceListRow(
                id: id, height: 64,
                content: AnyView(
                    CatalogCardButton(
                        isPointerRevealed: false,
                        action: {
                            probe.activations += 1; probe.lastActivated = id
                        }
                    ) { isFocused in
                        Text(id).opacity(isFocused ? 1 : 0)
                            .onAppear { probe.appeared.insert(id) }
                            .onChange(of: isFocused) { _, focused in
                                if focused { probe.focused = id }
                            }
                    }))
        }
        let content = NativeOccurrenceList(
            rows: rows, selection: .constant(["second"]), allowsMultipleSelection: false,
            accessibilityLabel: "Fixture")
        let coordinator = NativeOccurrenceList.Coordinator(content)
        coordinator.attach(to: scroll)
        defer { coordinator.detach(from: scroll) }
        coordinator.update(content, in: scroll)
        try await requireEventually {
            scroll.layoutSubtreeIfNeeded()
            return probe.appeared.count == 2
        }
        try #require(window.makeFirstResponder(scroll.table))
        let tab = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        scroll.table.keyDown(with: tab)
        if rapidEntry {
            window.sendEvent(tab)
            try await requireEventually { nextField.currentEditor() === window.firstResponder }
            try #require(window.makeFirstResponder(scroll.table))
            scroll.table.keyDown(with: tab)
        }
        try await requireEventually { probe.focused == "second" }
        var artworkResponder = try #require(window.firstResponder)
        let focusedCell = try #require(
            scroll.table.view(atColumn: 0, row: 1, makeIfNecessary: false) as? NativeTrackHostingCell)
        let focusedControl = try #require(focusedCell.focusTarget.control)
        #expect(artworkResponder !== scroll.table && artworkResponder !== nextField.currentEditor())
        #expect(probe.activations == 0)
        #expect(scroll.table.selectedRowIndexes == IndexSet(integer: 1))

        let heading = NativeOccurrenceListRow(
            id: "heading", height: 40, isSelectable: false, content: AnyView(Text("Section")))
        let updated = NativeOccurrenceList(
            rows: [heading] + rows, selection: .constant(["second"]), allowsMultipleSelection: false,
            accessibilityLabel: "Fixture")
        coordinator.update(updated, in: scroll)
        let sameCell = scroll.table.view(atColumn: 0, row: 2, makeIfNecessary: false) === focusedCell
        #expect(sameCell)
        #expect(focusedCell.focusTarget.control === focusedControl)
        try await requireEventually { focusedControl.hasKeyboardFocus }
        for count in 1...2 {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                window.sendEvent(
                    try #require(
                        NSEvent.keyEvent(
                            with: type, location: .zero, modifierFlags: [], timestamp: 0,
                            windowNumber: window.windowNumber, context: nil, characters: " ",
                            charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)))
            }
            try await requireEventually { probe.activations == count }
            #expect(probe.lastActivated == "second")
        }
        coordinator.update(content, in: scroll)
        try await requireEventually { focusedControl.hasKeyboardFocus }
        artworkResponder = try #require(window.firstResponder)

        window.sendEvent(tab)
        try await requireEventually { nextField.currentEditor() === window.firstResponder }

        try #require(window.makeFirstResponder(scroll.table))
        window.sendEvent(tab)
        try await requireEventually { window.firstResponder !== scroll.table }
        let backTab = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0,
                windowNumber: window.windowNumber, context: nil,
                characters: "\u{19}", charactersIgnoringModifiers: "\u{19}", isARepeat: false, keyCode: 48))
        window.sendEvent(backTab)
        try await requireEventually { window.firstResponder === scroll.table }
        #expect(scroll.table.selectedRowIndexes == IndexSet(integer: 1))

        window.sendEvent(tab)
        window.sendEvent(backTab)
        window.sendEvent(tab)
        try await requireEventually { window.firstResponder === artworkResponder }
        window.sendEvent(backTab)
        try await requireEventually { window.firstResponder === scroll.table }

        scroll.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try #require(window.makeFirstResponder(scroll.table))
        scroll.table.keyDown(with: tab)
        try await requireEventually { probe.focused == "first" }
        #expect(probe.activations == 2)
    }

    @Test(arguments: [false, true])
    func insertingAndRemovingOtherRowsKeepsTheFocusedControlAttached(mixedHeights: Bool) async throws {
        let scroll = NativeOccurrenceScrollView(frame: NSRect(x: 0, y: 0, width: 208, height: 400))
        let window = NSWindow(
            contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        defer { window.contentView = nil }
        let probe = FocusProbe()
        let folder = NativeOccurrenceListRow(id: "folder", height: 64, content: AnyView(ProbeButton(probe: probe)))
        let sibling = NativeOccurrenceListRow(
            id: "sibling", height: mixedHeights ? 40 : 64, content: AnyView(Text("Sibling")))
        let children = (0..<3).map {
            NativeOccurrenceListRow(
                id: "child-\($0)", height: mixedHeights ? 56 : 64, content: AnyView(Text("Child \($0)")))
        }
        func content(_ rows: [NativeOccurrenceListRow]) -> NativeOccurrenceList {
            NativeOccurrenceList(
                rows: rows, selection: .constant(["folder"]), allowsMultipleSelection: false,
                preservesVisibleAnchor: true, accessibilityLabel: "Fixture")
        }
        let coordinator = NativeOccurrenceList.Coordinator(content([folder, sibling]))
        coordinator.attach(to: scroll)
        defer { coordinator.detach(from: scroll) }
        coordinator.update(content([folder, sibling]), in: scroll)
        try await requireEventually {
            scroll.layoutSubtreeIfNeeded()
            return probe.button?.window === window
        }
        let button = try #require(probe.button)
        try #require(window.makeFirstResponder(button))
        try #require(window.firstResponder === button)

        coordinator.update(content([folder] + children + [sibling]), in: scroll)
        #expect(
            window.firstResponder === button, "Expanding another part of the list must preserve its focused control")
        #expect(probe.button === button, "A stable occurrence keeps its native leaf")
        #expect(scroll.table.numberOfRows == 5)
        #expect(scroll.table.selectedRowIndexes == IndexSet(integer: 0))
        coordinator.update(content([folder, sibling]), in: scroll)
        #expect(window.firstResponder === button, "Collapsing child rows cannot drop keyboard focus")
        #expect(probe.button === button)
        #expect(scroll.table.numberOfRows == 2)

        coordinator.update(content(children + [folder, sibling]), in: scroll)
        #expect(window.firstResponder === button, "A retained cell also keeps focus when earlier rows shift its index")
        #expect(scroll.table.selectedRowIndexes == IndexSet(integer: 3))
        #expect(scroll.table.rect(ofRow: 4).minY == (mixedHeights ? 232 : 256))
        coordinator.update(content([sibling]), in: scroll)
        #expect(window.firstResponder !== button, "A removed control cannot retain input focus")

        let tallerFolder = NativeOccurrenceListRow(id: "folder", height: 96, content: folder.content)
        coordinator.update(content([tallerFolder, sibling]), in: scroll)
        #expect(scroll.table.rect(ofRow: 1).minY == 96, "Changed row heights retain the full-reload geometry path")
    }

    @Test func playingGlyphPreservesTheFocusedTrackControl() async throws {
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make())
        let track = HarnessFixtures.track(uri: "spotify:track:focus")
        player.send(.session(.ready), source: .account)
        func present(playing: Bool) {
            player.send(
                .presentation(
                    PlaybackPresentationSnapshot(
                        currentTrack: CurrentTrack(
                            uri: track.uri, title: track.title, artist: track.artist,
                            duration: track.duration, metadataSource: .catalog),
                        transport: playing ? .playing : .paused,
                        timing: PlaybackTiming(position: 5, duration: track.duration, anchoredAt: HarnessDates.fixed))),
                source: .user)
        }
        present(playing: false)
        let probe = FocusProbe()
        let row = NativeOccurrenceListRow(
            id: track.id, height: 56,
            content: AnyView(IndexCellFixture(player: player, track: track, probe: probe)))
        let harness = HostedSurfaceHarness(
            NativeOccurrenceList(
                rows: [row], selection: .constant([track.id]),
                accessibilityLabel: "Discography"))
        defer { harness.detach() }
        let table = try await harness.table()
        let cell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: false) as? NativeTrackHostingCell)
        try await requireEventually { cell.focusTarget.control != nil }
        try #require(harness.window.makeFirstResponder(table))
        table.keyDown(with: try harness.key(48, "\t"))
        try await requireEventually {
            harness.host.layoutSubtreeIfNeeded()
            return cell.focusTarget.control?.hasKeyboardFocus == true
                && harness.window.firstResponder !== table && harness.window.firstResponder !== harness.window
        }
        let responder = harness.window.firstResponder
        let control = cell.focusTarget.control
        for playing in [true, false, true, false] {
            present(playing: playing)
            try await requireEventually {
                harness.host.layoutSubtreeIfNeeded()
                return probe.observedPlaying == playing
            }
            let retained = harness.window.firstResponder === responder
            #expect(retained, "Changing between a track number and its playing glyph must keep keyboard focus")
            #expect(cell.focusTarget.control === control)
            #expect(control?.hasKeyboardFocus == true)
        }
        await player.shutdownForTermination()
    }

    @Test func offscreenMixedInsertionsPreserveTheFocusedControlAndExactAnchor() async throws {
        let state = NativeListScrollState()
        state.offset = 640
        let probe = FocusProbe()
        let rows = (0..<40).map { index in
            NativeOccurrenceListRow(
                id: "row-\(index)", height: 64,
                content: index == 10 ? AnyView(ProbeButton(probe: probe)) : AnyView(Text("Row \(index)")))
        }
        let inserted = (0..<6).map {
            NativeOccurrenceListRow(id: "track-\($0)", height: 56, content: AnyView(Text("Track")))
        }
        func content(_ rows: [NativeOccurrenceListRow]) -> NativeOccurrenceList {
            NativeOccurrenceList(
                rows: rows, selection: .constant(["row-10"]),
                preservesVisibleAnchor: true, accessibilityLabel: "Discography", scrollState: state)
        }
        let scroll = NativeOccurrenceScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        defer { window.contentView = nil }
        let coordinator = NativeOccurrenceList.Coordinator(content(rows))
        coordinator.attach(to: scroll)
        defer { coordinator.detach(from: scroll) }
        coordinator.update(content(rows), in: scroll)
        try await requireEventually {
            scroll.layoutSubtreeIfNeeded()
            return probe.button?.window === window
        }
        let button = try #require(probe.button)
        try #require(window.makeFirstResponder(button))
        let expanded = Array(rows.prefix(2)) + inserted + Array(rows.dropFirst(2))
        coordinator.update(content(expanded), in: scroll)
        #expect(window.firstResponder === button)
        #expect(scroll.table.rect(ofRow: 16).minY == 976)
        #expect(scroll.contentView.bounds.minY == 976)
        #expect(state.offset == 976)
        #expect(scroll.table.selectedRow == 16)
        coordinator.update(content(rows), in: scroll)
        #expect(window.firstResponder === button)
        #expect(scroll.table.rect(ofRow: 10).minY == 640)
        #expect(scroll.contentView.bounds.minY == 640)
        state.offset = 0
        coordinator.update(content(expanded), in: scroll)
        #expect(scroll.contentView.bounds.minY == 0)
        #expect(state.offset == 0)
    }

    @Test func accountReplacementRelinquishesFocusEvenWhenOccurrenceIDsSurvive() async throws {
        let probe = FocusProbe()
        let content = NativeOccurrenceList(
            rows: [NativeOccurrenceListRow(id: "same", height: 64, content: AnyView(ProbeButton(probe: probe)))],
            selection: .constant(["same"]), accessibilityLabel: "Fixture")
        let harness = HostedSurfaceHarness(content.environment(\.artworkAccess, ArtworkAccess(accountEpoch: 1)))
        defer { harness.detach() }
        let table = try await harness.table()
        try await requireEventually { probe.button?.window === harness.window }
        let button = try #require(probe.button)
        let cell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: false) as? NativeTrackHostingCell)
        let oldTarget = cell.focusTarget
        try #require(harness.window.makeFirstResponder(button))
        harness.host.rootView = AnyView(content.environment(\.artworkAccess, ArtworkAccess(accountEpoch: 2)))
        try await requireEventually {
            harness.host.layoutSubtreeIfNeeded()
            return cell.focusTarget !== oldTarget
        }
        #expect(harness.window.firstResponder !== button)
        #expect(oldTarget.table == nil)
        #expect(oldTarget.control == nil)
        #expect(!oldTarget.focus())
    }

    @MainActor
    private final class FocusProbe {
        weak var button: NSButton?
        var observedPlaying = false
    }

    @MainActor
    private final class ArtworkFocusProbe {
        var appeared: Set<String> = []
        var focused: String?
        var activations = 0
        var lastActivated: String?
    }

    private struct IndexCellFixture: View {
        let player: PlaybackStore
        let track: CatalogTrack
        let probe: FocusProbe
        var body: some View {
            NativeTrackCell(
                row: TrackTableRow(track: track, sourceIndex: 0), column: .index,
                position: 1, total: 1, variant: .album, isSelected: true,
                playback: CatalogPlaybackAccess(player: player), searchQuery: "", onSelect: nil
            )
            .onChange(of: player.isPlaying) { _, value in probe.observedPlaying = value }
        }
    }

    private struct ProbeButton: NSViewRepresentable {
        let probe: FocusProbe

        func makeNSView(context: Context) -> NSButton {
            let button = NSButton(title: "Expand folder", target: nil, action: nil)
            probe.button = button
            return button
        }

        func updateNSView(_ button: NSButton, context: Context) {}
    }
}
