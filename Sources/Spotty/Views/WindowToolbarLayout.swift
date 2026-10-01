import AppKit
import SwiftUI

/// AppKit's unified icon row is 52pt. Its standard label mode reserves a 66pt
/// row, giving the custom controls room for Spotify's 8pt top margin while
/// leaving all standard window buttons and titlebar interaction to AppKit.
struct WindowToolbarLayout: NSViewRepresentable {
    func makeNSView(context: Context) -> ToolbarLayoutView { ToolbarLayoutView() }

    func updateNSView(_ view: ToolbarLayoutView, context: Context) { view.configureToolbar() }

    static func dismantleNSView(_ view: ToolbarLayoutView, coordinator: ()) {
        NotificationCenter.default.removeObserver(view)
    }

    final class ToolbarLayoutView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let window {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(windowDidUpdate(_:)), name: NSWindow.didUpdateNotification,
                    object: window)
            }
            configureToolbar()
        }

        @objc private func windowDidUpdate(_: Notification) { configureToolbar() }

        func configureToolbar() {
            guard let toolbar = window?.toolbar, toolbar.displayMode != .iconAndLabel else { return }
            toolbar.displayMode = .iconAndLabel
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
