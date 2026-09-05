import AppKit
import SwiftUI

/// Reads the native list's scroll position without taking over scrolling or selection.
struct PlaylistScrollObserver: NSViewRepresentable {
    let threshold: CGFloat
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView() }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.threshold = threshold
        view.onChange = onChange
        view.attach()
    }

    static func dismantleNSView(_ view: ObserverView, coordinator: ()) {
        view.detach()
    }

    final class ObserverView: NSView {
        var threshold: CGFloat = 0
        var onChange: ((Bool) -> Void)?
        private weak var clipView: NSClipView?
        private var lastValue: Bool?
        private var previouslyPostedBoundsChanges = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { detach() } else { attach() }
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            attach()
        }

        func attach() {
            guard let clip = enclosingScrollView?.contentView else { return }
            if clipView !== clip {
                detach()
                clipView = clip
                previouslyPostedBoundsChanges = clip.postsBoundsChangedNotifications
                clip.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(
                    self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: clip)
            }
            // A virtualized header can reattach after the scroll event that brought it back.
            DispatchQueue.main.async { [weak self] in self?.updateCompactState() }
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            clipView?.postsBoundsChangedNotifications = previouslyPostedBoundsChanges
            clipView = nil
        }

        @objc private func boundsChanged(_ notification: Notification) {
            updateCompactState()
        }

        private func updateCompactState() {
            guard let clipView, threshold > 0 else { return }
            let compact = clipView.bounds.minY >= threshold
            guard lastValue != compact else { return }
            lastValue = compact
            onChange?(compact)
        }
    }
}
