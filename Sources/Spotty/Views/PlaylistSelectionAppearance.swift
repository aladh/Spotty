import AppKit
import SwiftUI

/// Retain native list selection and keyboard handling, while the row draws its highlight.
struct PlaylistSelectionAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> SelectionView { SelectionView() }

    func updateNSView(_ nsView: SelectionView, context: Context) {
        nsView.suppressSystemHighlight()
    }

    final class SelectionView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            suppressSystemHighlight()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            suppressSystemHighlight()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func suppressSystemHighlight() {
            var ancestor = superview
            while let view = ancestor {
                if let table = view as? NSTableView {
                    table.selectionHighlightStyle = .none
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
