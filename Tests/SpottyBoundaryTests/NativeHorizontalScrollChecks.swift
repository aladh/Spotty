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

    @Test func horizontalWheelStaysInShelfAndContentFitsAfterResize() throws {
        let shelf = NativeHorizontalScrollView(content: AnyView(Color.clear.frame(width: 1200, height: 240)))
        let page = ScrollReceiver()
        shelf.nextResponder = page
        shelf.frame = NSRect(x: 0, y: 0, width: 600, height: 240)
        shelf.layoutSubtreeIfNeeded()
        try #require(shelf.documentView).scrollWheel(with: wheel(x: -80, y: 0))
        #expect(page.verticalDeltas.isEmpty)
        #expect(shelf.documentView?.frame.width == 1200)
        #expect(shelf.hostedSize.height == 240)

        // Verify the scroll range and resize clamp without relying on offscreen wheel animation.
        shelf.contentView.scroll(to: NSPoint(x: 300, y: 0))
        shelf.reflectScrolledClipView(shelf.contentView)
        #expect(shelf.contentView.bounds.minX == 300)

        shelf.frame.size.width = 1400
        shelf.layoutSubtreeIfNeeded()
        #expect(shelf.documentView?.frame.width == shelf.contentSize.width)
        #expect(shelf.contentView.bounds.minX == 0)
    }

    @Test func verticalGestureKeepsItsResponderThroughDiagonalChangesAndMomentum() throws {
        let shelf = NativeHorizontalScrollView(content: AnyView(Color.clear.frame(width: 1200, height: 240)))
        let page = ScrollReceiver()
        shelf.nextResponder = page
        let momentumChanged = try #require(CGMomentumScrollPhase(rawValue: 2))  // kCGMomentumScrollPhaseContinue
        let events = try [
            wheel(x: 0, y: 0, phase: .began),
            wheel(x: -5, y: -80, phase: .changed),
            wheel(x: -80, y: -5, phase: .changed),
            wheel(x: 0, y: 0, phase: .ended),
            wheel(x: -80, y: -5, momentum: .begin),
            wheel(x: -40, y: -2, momentum: momentumChanged),
            wheel(x: 0, y: 0, momentum: .end),
        ]
        #expect(events[0].phase == .began)
        #expect(events[4].momentumPhase == .began)
        #expect(events[5].momentumPhase == .changed)
        for event in events { try #require(shelf.documentView).scrollWheel(with: event) }
        #expect(page.verticalDeltas == [0, -80, -5, 0, -5, -2, 0])
        #expect(page.phases == [.began, .changed, .changed, .ended, [], [], []])

        // The next gesture chooses a fresh axis; its vertical tail stays in the shelf.
        shelf.scrollWheel(with: try wheel(x: -80, y: -5, phase: .began))
        shelf.scrollWheel(with: try wheel(x: -5, y: -80, phase: .changed))
        shelf.scrollWheel(with: try wheel(x: 0, y: 0, phase: .ended))
        shelf.scrollWheel(with: try wheel(x: -5, y: -80, momentum: .begin))
        shelf.scrollWheel(with: try wheel(x: 0, y: 0, momentum: .end))
        #expect(page.verticalDeltas.count == events.count)

        // Discrete mouse-wheel ticks independently choose their direction.
        shelf.scrollWheel(with: try wheel(x: 0, y: -40))
        #expect(page.verticalDeltas == [0, -80, -5, 0, -5, -2, 0, -40])
    }

    private func wheel(
        x: Int32, y: Int32, phase: CGScrollPhase? = nil, momentum: CGMomentumScrollPhase = .none
    ) throws -> NSEvent {
        let event = try #require(
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0))
        event.flags = []
        if let phase {
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        }
        if momentum != .none {
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
        }
        return try #require(NSEvent(cgEvent: event))
    }
}

/// Observe responder delivery without depending on AppKit's asynchronous wheel animation.
@MainActor
private final class ScrollReceiver: NSScrollView {
    var verticalDeltas: [CGFloat] = []
    var phases: [NSEvent.Phase] = []
    override func scrollWheel(with event: NSEvent) {
        verticalDeltas.append(event.scrollingDeltaY)
        phases.append(event.phase)
    }
}
