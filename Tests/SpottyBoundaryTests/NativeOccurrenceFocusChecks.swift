import AppKit
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
                    CatalogCardButton(isPointerRevealed: false, action: { probe.activations += 1 }) { isFocused in
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
        let artworkResponder = try #require(window.firstResponder)
        #expect(artworkResponder !== scroll.table && artworkResponder !== nextField.currentEditor())
        #expect(probe.activations == 0)
        #expect(scroll.table.selectedRowIndexes == IndexSet(integer: 1))

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
        #expect(probe.activations == 0)
    }

    @Test func insertingAndRemovingOtherRowsKeepsTheFocusedControlAttached() async throws {
        let scroll = NativeOccurrenceScrollView(frame: NSRect(x: 0, y: 0, width: 208, height: 400))
        let window = NSWindow(
            contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        defer { window.contentView = nil }
        let probe = FocusProbe()
        let folder = NativeOccurrenceListRow(id: "folder", height: 64, content: AnyView(ProbeButton(probe: probe)))
        let sibling = NativeOccurrenceListRow(id: "sibling", height: 64, content: AnyView(Text("Sibling")))
        let children = (0..<3).map {
            NativeOccurrenceListRow(id: "child-\($0)", height: 64, content: AnyView(Text("Child \($0)")))
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
        #expect(scroll.table.rect(ofRow: 4).minY == 256)
        coordinator.update(content([sibling]), in: scroll)
        #expect(window.firstResponder !== button, "A removed control cannot retain input focus")

        let tallerFolder = NativeOccurrenceListRow(id: "folder", height: 96, content: folder.content)
        coordinator.update(content([tallerFolder, sibling]), in: scroll)
        #expect(scroll.table.rect(ofRow: 1).minY == 96, "Changed row heights retain the full-reload geometry path")
    }

    @MainActor
    private final class FocusProbe {
        weak var button: NSButton?
    }

    @MainActor
    private final class ArtworkFocusProbe {
        var appeared: Set<String> = []
        var focused: String?
        var activations = 0
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
