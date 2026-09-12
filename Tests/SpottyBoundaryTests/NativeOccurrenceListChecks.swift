import AppKit
import SwiftUI
import Testing
@testable import SpottyCore

@Suite("Owned native occurrence list")
@MainActor
struct NativeOccurrenceListChecks {
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
