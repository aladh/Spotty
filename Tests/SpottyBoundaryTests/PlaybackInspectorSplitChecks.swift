import AppKit
import SwiftUI
import SpottyTestSupport
import Testing
@testable import SpottyCore

@Suite("Playback inspector split")
@MainActor
struct PlaybackInspectorSplitChecks {
    @Test func resizingAndReopeningPreserveTheInspectorWidthAndCatalogHost() async throws {
        let controller = PlaybackInspectorSplit<Color, Color>.Controller(
            content: AnyView(Color.black.frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)),
            inspector: AnyView(Color.black.frame(minWidth: 260, maxWidth: 360, maxHeight: .infinity)),
            isPresented: false)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 700), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentViewController = controller
        defer { window.orderOut(nil); window.contentViewController = nil }
        window.setContentSize(NSSize(width: 1080, height: 700))
        window.orderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.splitView.bounds.width == 1080)
        let contentHost = controller.contentHost
        let inspector = try #require(controller.splitViewItems.last)
        #expect(inspector.isCollapsed)
        #expect(!inspector.canCollapse, "Divider gestures cannot silently change scene presentation")
        controller.setPresented(true)
        controller.view.layoutSubtreeIfNeeded()
        let initialWidth = controller.inspectorHost.view.frame.width
        #expect((260...280).contains(initialWidth))
        controller.splitView.setPosition(controller.splitView.bounds.width - 330, ofDividerAt: 0)
        controller.view.layoutSubtreeIfNeeded()
        try await requireEventually { controller.inspectorHost.view.frame.width > initialWidth + 20 }
        let resizedWidth = controller.inspectorHost.view.frame.width
        #expect(resizedWidth > initialWidth + 20)
        #expect(resizedWidth <= 360)
        controller.setPresented(false)
        controller.view.layoutSubtreeIfNeeded()
        #expect(inspector.isCollapsed)
        controller.setPresented(true)
        controller.view.layoutSubtreeIfNeeded()
        #expect(!inspector.isCollapsed)
        #expect(abs(controller.inspectorHost.view.frame.width - resizedWidth) <= 2)
        #expect(controller.contentHost === contentHost, "Presentation must preserve the catalog host")
        window.setContentSize(NSSize(width: 960, height: 640))
        controller.view.layoutSubtreeIfNeeded()
        #expect(abs(controller.inspectorHost.view.frame.width - resizedWidth) <= 2)
    }
}
