import AppKit
import SwiftUI

/// An owned geometry anchor reveals focus through both the shelf and the containing page.
struct CatalogCardFocusReveal: NSViewRepresentable {
    let isFocused: Bool

    func makeNSView(context: Context) -> CatalogCardFocusView { CatalogCardFocusView() }

    func updateNSView(_ view: CatalogCardFocusView, context: Context) {
        view.updateFocus(isFocused)
    }
}

@MainActor
final class CatalogCardFocusView: NSView {
    private var isFocused = false
    private var needsReveal = false

    func updateFocus(_ focused: Bool) {
        guard isFocused != focused else { return }
        isFocused = focused
        needsReveal = focused
        revealIfReady()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        revealIfReady()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        revealIfReady()
    }

    private func revealIfReady() {
        guard needsReveal, window != nil, !bounds.isEmpty else { return }
        needsReveal = false
        // Use public scroll owners and coordinate conversion, independent of SwiftUI's view classes.
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? NSScrollView, let document = scroll.documentView {
                document.scrollToVisible(convert(bounds, to: document))
            }
            ancestor = view.superview
        }
    }
}
