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
        var canRequestFirst = true
        first.registerFocus(target: target) {
            guard canRequestFirst else { return false }
            firstRequests += 1
            return true
        }
        #expect(!target.focus(), "Detached row controls cannot consume Tab")
        #expect(!target.leaveControl(backwards: false))
        #expect(!target.leaveControl(backwards: true))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless],
            backing: .buffered, defer: false)
        let root = NSView(frame: window.contentLayoutRect)
        window.contentView = root
        defer { window.contentView = nil }
        let table = NSTableView(frame: root.bounds)
        root.addSubview(table)
        target.table = table
        target.host = root
        root.addSubview(first)
        root.addSubview(second)
        #expect(target.focus())
        #expect(firstRequests == 1)
        first.updateFocus(true)
        #expect(target.focus(), "Accessibility reveal alone must not prevent keyboard entry")
        canRequestFirst = false
        #expect(!target.focus(), "A rejected request must not consume Tab even before the anchor is updated")
        first.updateFocus(false)
        first.registerFocus(target: target, request: nil)
        #expect(!target.focus(), "Disabled controls let native traversal continue")
        second.registerFocus(target: target) {
            secondRequests += 1
            return true
        }
        first.registerFocus(target: nil, request: nil)
        #expect(target.focus(), "Retiring an old leaf cannot unregister its replacement")
        #expect(firstRequests == 2 && secondRequests == 1)
        second.frame.size = .zero
        #expect(!target.focus(), "Unlaid-out controls cannot consume Tab")
        second.frame.size = NSSize(width: 48, height: 48)
        second.removeFromSuperview()
        #expect(!target.focus())
    }

    @Test func nativeRowTraversalOnlyConsumesActualForwardMovement() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless],
            backing: .buffered, defer: false)
        let root = NSView(frame: window.contentLayoutRect)
        window.contentView = root
        window.autorecalculatesKeyViewLoop = false
        defer { window.contentView = nil }
        let table = NSTableView(frame: NSRect(x: 0, y: 40, width: 200, height: 160))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        let anchor = CatalogCardFocusView(frame: NSRect(x: 0, y: 40, width: 48, height: 48))
        root.addSubview(table)
        root.addSubview(field)
        root.addSubview(anchor)
        let target = NativeRowFocusTarget()
        target.table = table
        target.host = root
        anchor.registerFocus(target: target, request: nil)
        table.nextKeyView = field
        field.nextKeyView = table
        try #require(window.makeFirstResponder(table))
        #expect(target.leaveControl(backwards: false))
        #expect(window.firstResponder === field.currentEditor())
        #expect(!target.leaveControl(backwards: false), "Wrapping to the same field must not claim a focus move")
        table.nextKeyView = nil
        #expect(!target.leaveControl(backwards: false), "A missing key-view destination must leave Tab unhandled")
        #expect(window.firstResponder === field.currentEditor())
    }

    @Test(arguments: ["1:replacement", "2:original"])
    func reusedCellRejectsRetiringArtworkBeforeSwiftUICommits(replacementID: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless],
            backing: .buffered, defer: false)
        let root = NSView(frame: window.contentLayoutRect)
        window.contentView = root
        defer { window.contentView = nil }
        let table = NSTableView(frame: root.bounds)
        root.addSubview(table)
        let cell = NativeTrackHostingCell()
        cell.frame = NSRect(x: 0, y: 0, width: 100, height: 64)
        root.addSubview(cell)
        let first = CatalogCardFocusView(frame: NSRect(x: 0, y: 0, width: 48, height: 48))
        cell.host.addSubview(first)
        cell.prepareFocusTarget(contentID: "1:original", table: table)
        let retiring = cell.focusTarget
        var oldRequests = 0
        first.registerFocus(target: retiring) {
            oldRequests += 1
            return true
        }
        #expect(retiring.focus())
        cell.prepareFocusTarget(contentID: "1:original", table: table)
        #expect(cell.focusTarget === retiring, "Metadata updates preserve the registered control")
        #expect(cell.focusTarget.focus())

        cell.prepareFocusTarget(contentID: replacementID, table: table)
        #expect(first.window === window, "The old SwiftUI leaf has not detached yet")
        #expect(!cell.focusTarget.focus(), "A reused cell cannot route Tab into its retiring occurrence")
        first.registerFocus(target: retiring) {
            oldRequests += 1
            return true
        }
        #expect(!retiring.focus(), "Late registration cannot reactivate a retired target")
        #expect(!cell.focusTarget.focus(), "An old update cannot register against the replacement target")
        #expect(oldRequests == 2)

        let replacement = CatalogCardFocusView(frame: NSRect(x: 48, y: 0, width: 48, height: 48))
        cell.host.addSubview(replacement)
        var newRequests = 0
        replacement.registerFocus(target: cell.focusTarget) {
            newRequests += 1
            return true
        }
        first.registerFocus(target: nil, request: nil)
        #expect(cell.focusTarget.focus())
        #expect(newRequests == 1)
        root.addSubview(replacement)
        #expect(!cell.focusTarget.focus(), "Being in the same window does not prove ownership by this cell")
        cell.host.addSubview(replacement)
        table.removeFromSuperview()
        #expect(!cell.focusTarget.focus(), "The target's table must still belong to the same window")
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
