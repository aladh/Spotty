import AppKit
import SwiftUI

/// Aligns the native window controls with the custom navigation header.
struct WindowButtonAlignment: NSViewRepresentable {
    func makeNSView(context: Context) -> AlignmentView {
        AlignmentView()
    }

    func updateNSView(_ nsView: AlignmentView, context: Context) {
        nsView.needsLayout = true
    }

    final class AlignmentView: NSView {
        private var isAligning = false
        private var alignmentScheduled = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            for name in [
                NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification,
                NSWindow.didUpdateNotification, NSWindow.didBecomeKeyNotification,
            ] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(scheduleAlignment), name: name, object: window
                )
            }
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(kind) else { continue }
                observeFrame(of: button)
                if let container = button.superview, kind == .closeButton {
                    observeFrame(of: container)
                }
            }
            needsLayout = true
        }

        private func observeFrame(of view: NSView) {
            view.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(scheduleAlignment), name: NSView.frameDidChangeNotification, object: view
            )
        }

        override func layout() {
            super.layout()
            scheduleAlignment()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        @objc private func scheduleAlignment() {
            guard !isAligning, !alignmentScheduled else { return }
            alignmentScheduled = true
            // AppKit lays out the standard buttons individually. Wait until the entire
            // layout transaction finishes before changing their shared geometry.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.alignmentScheduled = false
                self.alignButtons()
            }
        }

        private func alignButtons() {
            guard !isAligning, let window, !window.styleMask.contains(.fullScreen),
                bounds.height > 0,
                let close = window.standardWindowButton(.closeButton),
                let container = close.superview
            else { return }

            isAligning = true
            defer { isAligning = false }
            let height = bounds.height
            var frame = container.frame
            if container.superview?.isFlipped != true {
                frame.origin.y += frame.height - height
            }
            frame.size.height = height
            if container.frame != frame { container.frame = frame }
            for (index, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
                guard let button = window.standardWindowButton(kind) else { continue }
                let target = NSRect(x: 20 + CGFloat(index) * 23, y: (height - 14) / 2, width: 14, height: 14)
                if button.frame != target { button.frame = target }
            }
        }
    }
}
