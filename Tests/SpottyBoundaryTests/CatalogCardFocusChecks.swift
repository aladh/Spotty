import AppKit
import Testing
@testable import SpottyCore

@Suite("Catalog card focus visibility")
@MainActor
struct CatalogCardFocusChecks {
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
