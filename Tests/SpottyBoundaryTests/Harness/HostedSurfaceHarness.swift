import AppKit
import SwiftUI
import Testing
@testable import SpottyCore

/// Hosts production views in an attached window using owned controls and public AppKit input.
/// No SwiftUI private class names or guessed responder hierarchy.
@MainActor
final class HostedSurfaceHarness {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless],
        backing: .buffered, defer: false)
    let host: NSHostingView<AnyView>

    init(_ content: some View) {
        host = NSHostingView(rootView: AnyView(content))
        window.contentView = host
        window.layoutIfNeeded()
    }

    func detach() { window.contentView = nil }

    func table() async throws -> NativeTrackTableView {
        func find(_ view: NSView) -> NativeTrackTableView? {
            if let table = view as? NativeTrackTableView { return table }
            return view.subviews.lazy.compactMap(find).first
        }
        try await requireEventually {
            self.host.layoutSubtreeIfNeeded()
            return find(self.host)?.numberOfRows ?? 0 > 0
        }
        let table = try #require(find(host))
        try #require(table.window === window, "Never test a detached table retained by an old view tree")
        return table
    }

    func activatePlaybackControl() async throws {
        func find(_ view: NSView) -> CatalogCardFocusView? {
            if let control = view as? CatalogCardFocusView { return control }
            return view.subviews.lazy.compactMap(find).first
        }
        var focused = false
        try await requireEventually {
            self.host.layoutSubtreeIfNeeded()
            if !focused { focused = find(self.host)?.requestKeyboardFocus() == true }
            self.host.layoutSubtreeIfNeeded()
            return focused && self.window.firstResponder !== self.window
        }
        window.sendEvent(try key(49, " "))
        window.sendEvent(try key(49, " ", up: true))
    }

    func key(_ code: UInt16, _ characters: String, shift: Bool = false, up: Bool = false, repeatKey: Bool = false)
        throws -> NSEvent
    {
        try #require(
            NSEvent.keyEvent(
                with: up ? .keyUp : .keyDown, location: .zero, modifierFlags: shift ? .shift : [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: repeatKey, keyCode: code))
    }

}
