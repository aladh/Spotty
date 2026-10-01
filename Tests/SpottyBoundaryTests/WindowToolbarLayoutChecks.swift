import AppKit
import SwiftUI
import Testing
@testable import SpottyCore

@Suite("Native navigation titlebar")
@MainActor
struct WindowToolbarLayoutChecks {
    @Test func attachmentIsIdempotentAndRemovalRestoresThePreviousToolbar() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1220, height: 780),
            styleMask: [.titled], backing: .buffered, defer: false)
        let previous = NSToolbar(identifier: "test.previous")
        window.toolbar = previous
        let content = try #require(window.contentView)
        let baseline = window.titlebarAccessoryViewControllers.count
        let probe = WindowToolbarLayout<Color, Color>.ToolbarLayoutView(
            history: AnyView(Color.black.frame(width: 66, height: 32)),
            navigation: AnyView(Color.black.frame(width: 530, height: 52)))
        content.addSubview(probe)
        let toolbar = try #require(window.toolbar)
        #expect(toolbar !== previous)
        #expect(toolbar.displayMode == .iconAndLabel)
        #expect(!toolbar.allowsDisplayModeCustomization)
        #expect(window.titlebarAccessoryViewControllers.count == baseline + 1)
        probe.install()
        #expect(window.titlebarAccessoryViewControllers.count == baseline + 1)
        probe.removeFromSuperview()
        #expect(window.toolbar === previous)
        #expect(window.titlebarAccessoryViewControllers.count == baseline)
        content.addSubview(probe)
        #expect(window.titlebarAccessoryViewControllers.count == baseline + 1)
        probe.removeFromSuperview()
        #expect(window.toolbar === previous)
        #expect(window.titlebarAccessoryViewControllers.count == baseline)
    }

    @Test func teardownPreservesAReplacementToolbar() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1220, height: 780),
            styleMask: [.titled], backing: .buffered, defer: false)
        let content = try #require(window.contentView)
        let baseline = window.titlebarAccessoryViewControllers.count
        let probe = WindowToolbarLayout<Color, Color>.ToolbarLayoutView(
            history: AnyView(Color.black), navigation: AnyView(Color.black))
        content.addSubview(probe)
        let replacement = NSToolbar(identifier: "test.replacement")
        window.toolbar = replacement
        probe.removeFromSuperview()
        #expect(window.toolbar === replacement)
        #expect(window.titlebarAccessoryViewControllers.count == baseline)
    }
}
