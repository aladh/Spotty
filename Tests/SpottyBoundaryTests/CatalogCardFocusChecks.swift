import AppKit
import Testing
@testable import SpottyCore

@Suite("Catalog card focus visibility")
@MainActor
struct CatalogCardFocusChecks {
    @Test func nativeRowFocusRejectsDetachedDisabledAndReplacedControls() {
        let target = NativeRowFocusTarget()
        let first = CatalogCardFocusView(frame: NSRect(x: 0, y: 0, width: 48, height: 48))
        let second = CatalogCardFocusView(frame: NSRect(x: 48, y: 0, width: 48, height: 48))
        var firstRequests = 0
        var secondRequests = 0
        first.registerFocus(target: target) { firstRequests += 1 }
        #expect(!target.focus(), "Detached row controls cannot consume Tab")
        #expect(!target.leaveControl(backwards: false))
        #expect(!target.leaveControl(backwards: true))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless],
            backing: .buffered, defer: false)
        let root = NSView(frame: window.contentLayoutRect)
        window.contentView = root
        defer { window.contentView = nil }
        root.addSubview(first)
        root.addSubview(second)
        #expect(target.focus())
        #expect(firstRequests == 1)
        first.updateFocus(true)
        #expect(target.focus(), "Accessibility reveal alone must not prevent keyboard entry")
        first.updateFocus(false)
        first.registerFocus(target: target, request: nil)
        #expect(!target.focus(), "Disabled controls let native traversal continue")
        second.registerFocus(target: target) { secondRequests += 1 }
        first.registerFocus(target: nil, request: nil)
        #expect(target.focus(), "Retiring an old leaf cannot unregister its replacement")
        #expect(firstRequests == 2 && secondRequests == 1)
        second.frame.size = .zero
        #expect(!target.focus(), "Unlaid-out controls cannot consume Tab")
        second.frame.size = NSSize(width: 48, height: 48)
        second.removeFromSuperview()
        #expect(!target.focus())
    }

    @Test func focusRevealsBothScrollAxesWithoutFightingLaterUserScrolling() {
        let fixture = Fixture()
        let anchor = fixture.anchor
        anchor.updateFocus(true)
        #expect(fixture.page.contentView.bounds.minY > 0)
        #expect(fixture.shelf.contentView.bounds.minX > 0)
        #expect(fixture.pageDocument.visibleRect.contains(anchor.convert(anchor.bounds, to: fixture.pageDocument)))
        #expect(fixture.shelf.contentView.bounds.contains(anchor.frame))

        fixture.page.contentView.scroll(to: .zero)
        fixture.page.reflectScrolledClipView(fixture.page.contentView)
        anchor.updateFocus(true)
        #expect(fixture.page.contentView.bounds.minY == 0, "ordinary view updates cannot undo a user's scroll")
        anchor.updateFocus(false)
        anchor.updateFocus(true)
        #expect(fixture.page.contentView.bounds.minY > 0)
    }

    @Test func focusWaitsForAttachmentAndGeometryWithoutScrollingUnfocusedCards() {
        let fixture = Fixture()
        fixture.anchor.removeFromSuperview()
        fixture.anchor.frame.size = .zero
        fixture.anchor.updateFocus(true)
        fixture.shelf.documentView?.addSubview(fixture.anchor)
        #expect(fixture.page.contentView.bounds.minY == 0)
        fixture.anchor.frame.size = NSSize(width: 176, height: 200)
        #expect(fixture.page.contentView.bounds.minY > 0)
        fixture.anchor.updateFocus(false)
        fixture.page.contentView.scroll(to: .zero)
        fixture.anchor.frame.size.height = 210
        #expect(fixture.page.contentView.bounds.minY == 0)
    }

    @Test func focusRevealsTheFinalOriginAfterSizeArrivesFirst() {
        let fixture = Fixture()
        fixture.anchor.frame = .zero
        fixture.anchor.updateFocus(true)
        fixture.anchor.frame.size = NSSize(width: 176, height: 200)
        #expect(fixture.shelf.contentView.bounds.minX == 0)
        fixture.anchor.frame.origin = NSPoint(x: 900, y: 20)
        #expect(fixture.shelf.contentView.bounds.contains(fixture.anchor.frame))

        fixture.anchor.updateFocus(false)
        fixture.shelf.contentView.scroll(to: .zero)
        fixture.anchor.frame.origin.x = 950
        #expect(fixture.shelf.contentView.bounds.minX == 0)
    }

    @MainActor
    private final class Fixture {
        let page = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let pageDocument = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 1600))
        let shelf = NSScrollView(frame: NSRect(x: 0, y: 900, width: 600, height: 240))
        let anchor = CatalogCardFocusView(frame: NSRect(x: 900, y: 20, width: 176, height: 200))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
            backing: .buffered, defer: false)

        init() {
            page.documentView = pageDocument
            pageDocument.addSubview(shelf)
            let shelfDocument = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 240))
            shelf.documentView = shelfDocument
            shelfDocument.addSubview(anchor)
            window.contentView = page
            page.layoutSubtreeIfNeeded()
            page.contentView.scroll(to: .zero)
            shelf.contentView.scroll(to: .zero)
        }
    }
}
