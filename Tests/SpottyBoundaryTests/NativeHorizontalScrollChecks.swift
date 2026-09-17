import AppKit
import SwiftUI
import Testing
@testable import SpottyCore

@Suite("Nested horizontal shelves")
@MainActor
struct NativeHorizontalScrollChecks {
    @Test func verticalWheelOverShelfReachesTheContainingPage() throws {
        let page = ScrollReceiver(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 1600))
        page.documentView = document
        let shelf = NativeHorizontalScrollView(content: AnyView(Color.clear.frame(width: 1200, height: 240)))
        shelf.frame = NSRect(x: 0, y: 500, width: 600, height: 240)
        document.addSubview(shelf)
        page.contentView.scroll(to: NSPoint(x: 0, y: 500))
        page.layoutSubtreeIfNeeded()
        shelf.layoutSubtreeIfNeeded()
        try #require(shelf.documentView).scrollWheel(with: wheel(x: 0, y: -80))

        #expect(page.verticalDeltas == [-80])
        #expect(shelf.contentView.bounds.minX == 0)
        #expect(shelf.contentView.bounds.minY == 0)
    }

    @Test func horizontalWheelStaysInShelfAndContentFitsAfterResize() async throws {
        let shelf = NativeHorizontalScrollView(content: AnyView(Color.clear.frame(width: 1200, height: 240)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 240), styleMask: .borderless,
            backing: .buffered, defer: false)
        window.contentView = shelf
        defer { window.contentView = nil }
        let page = ScrollReceiver()
        shelf.nextResponder = page
        shelf.frame = NSRect(x: 0, y: 0, width: 600, height: 240)
        shelf.layoutSubtreeIfNeeded()
        try #require(shelf.documentView).scrollWheel(with: wheel(x: -80, y: 0))
        try await requireEventually { shelf.contentView.bounds.minX > 0 }
        #expect(page.verticalDeltas.isEmpty)
        #expect(shelf.documentView?.frame.width == 1200)
        #expect(shelf.hostedSize.height == 240)

        shelf.frame.size.width = 1400
        shelf.layoutSubtreeIfNeeded()
        #expect(shelf.documentView?.frame.width == shelf.contentSize.width)
        #expect(shelf.contentView.bounds.minX == 0)
    }

    private func wheel(x: Int32, y: Int32) throws -> NSEvent {
        let event = try #require(
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0))
        return try #require(NSEvent(cgEvent: event))
    }
}

/// Observe responder delivery without depending on AppKit's asynchronous wheel animation.
@MainActor
private final class ScrollReceiver: NSScrollView {
    var verticalDeltas: [CGFloat] = []
    override func scrollWheel(with event: NSEvent) { verticalDeltas.append(event.scrollingDeltaY) }
}
