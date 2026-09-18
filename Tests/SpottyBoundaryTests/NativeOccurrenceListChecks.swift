import AppKit
import SwiftUI
import Testing
@testable import SpottyCore

@Suite("Owned native occurrence list")
@MainActor
struct NativeOccurrenceListChecks {
    @Test(arguments: [false, true])
    func insertedAlbumTracksKeepTheVisibleReleaseAndNativeSelectionAnchored(attached: Bool) {
        let state = NativeListScrollState()
        state.offset = 640
        var selection: Set<String> = ["occurrence-10"]
        let initial = NativeOccurrenceList(
            rows: content(count: 40, scrollState: state).rows,
            selection: Binding(get: { selection }, set: { selection = $0 }), preservesVisibleAnchor: true,
            accessibilityLabel: "Discography", scrollState: state)
        let scroll = NativeOccurrenceScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        if attached { window.contentView = scroll }
        defer { window.contentView = nil }
        let coordinator = NativeOccurrenceList.Coordinator(initial)
        coordinator.attach(to: scroll)
        coordinator.update(initial, in: scroll)
        #expect(scroll.table.selectedRowIndexes == IndexSet(integer: 10))
        let added = (0..<6).map {
            NativeOccurrenceListRow(id: "loaded-track-\($0)", height: 56, content: AnyView(Text("Loaded track")))
        }
        let updated = NativeOccurrenceList(
            rows: Array(initial.rows.prefix(2)) + added + Array(initial.rows.dropFirst(2)),
            selection: Binding(get: { selection }, set: { selection = $0 }), preservesVisibleAnchor: true,
            accessibilityLabel: "Discography", scrollState: state)
        coordinator.update(updated, in: scroll)
        #expect(abs(scroll.contentView.bounds.minY - (640 + 6 * 56)) < 1)
        #expect(scroll.table.selectedRowIndexes == IndexSet(integer: 16))
        state.offset = 0
        coordinator.update(initial, in: scroll)
        #expect(scroll.contentView.bounds.minY == 0, "an explicit filter reset takes priority over the anchor")
        coordinator.detach(from: scroll)
    }

    @Test func scrollStateSurvivesNativeListReplacementAndClampsToAvailableRows() {
        let state = NativeListScrollState()
        state.offset = 320
        let initial = content(count: 80, scrollState: state)
        let first = NativeOccurrenceScrollView(frame: NSRect(x: 0, y: 0, width: 280, height: 400))
        let coordinator = NativeOccurrenceList.Coordinator(initial)
        coordinator.attach(to: first)
        coordinator.update(initial, in: first)
        #expect(abs(first.contentView.bounds.minY - 320) < 1)

        first.contentView.scroll(to: NSPoint(x: 0, y: 640))
        first.reflectScrolledClipView(first.contentView)
        #expect(abs(state.offset - 640) < 1)
        coordinator.detach(from: first)

        let replacement = NativeOccurrenceScrollView(frame: NSRect(x: 0, y: 0, width: 280, height: 400))
        let replacementCoordinator = NativeOccurrenceList.Coordinator(initial)
        replacementCoordinator.attach(to: replacement)
        replacementCoordinator.update(initial, in: replacement)
        #expect(abs(replacement.contentView.bounds.minY - 640) < 1)

        first.contentView.scroll(to: NSPoint(x: 0, y: 32))
        #expect(abs(state.offset - 640) < 1)
        replacementCoordinator.update(content(count: 1, scrollState: state), in: replacement)
        #expect(replacement.contentView.bounds.minY == 0)
        #expect(state.offset == 0)
    }

    private func content(count: Int, scrollState: NativeListScrollState) -> NativeOccurrenceList {
        NativeOccurrenceList(
            rows: (0..<count).map { index in
                NativeOccurrenceListRow(
                    id: "occurrence-\(index)", height: 64, content: AnyView(Text("Fixture \(index)"))
                )
            },
            selection: .constant([]), accessibilityLabel: "Fixture", scrollState: scrollState
        )
    }
}
