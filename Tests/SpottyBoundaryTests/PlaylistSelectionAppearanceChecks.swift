import AppKit
import Testing
@testable import SpottyCore

@Suite("Playlist selection appearance")
@MainActor
struct PlaylistSelectionAppearanceChecks {
    @Test func sharedAttachmentRestoresOriginalStyleAndLeavesSelectionPolicyAlone() async {
        let scroll = NSScrollView()
        let table = NSTableView()
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = true
        scroll.documentView = table
        let first = PlaylistSelectionAppearance.SelectionView()
        let second = PlaylistSelectionAppearance.SelectionView()
        table.addSubview(first)
        table.addSubview(second)
        first.attach()
        first.attach()
        second.attach()
        #expect(table.selectionHighlightStyle == .none)
        #expect(table.allowsMultipleSelection)
        first.detach()
        #expect(table.selectionHighlightStyle == .none)
        second.detach()
        #expect(await waitUntil { table.selectionHighlightStyle == .regular })
        #expect(table.selectionHighlightStyle == .regular)
        #expect(table.allowsMultipleSelection)
    }

    @Test func unattachedAndReparentedViewsFailSafely() async {
        let view = PlaylistSelectionAppearance.SelectionView()
        view.attach()
        view.detach()
        let scroll = NSScrollView()
        let table = NSTableView()
        scroll.documentView = table
        table.selectionHighlightStyle = .regular
        table.addSubview(view)
        view.attach()
        #expect(table.selectionHighlightStyle == .none)
        view.removeFromSuperview()
        #expect(await waitUntil { table.selectionHighlightStyle == .regular })
        #expect(table.selectionHighlightStyle == .regular)
        #expect(view.hitTest(.zero) == nil)
    }
}
