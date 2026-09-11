import AppKit
import SwiftUI

/// SwiftUI's macOS plain List ignores tint for selection. Keep its selection machinery and
/// customize only drawing. This narrow bridge depends on an enclosing NSTableView; if SwiftUI
/// changes that structure, leave the native highlight intact rather than replacing interaction.
struct PlaylistSelectionAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> SelectionView { SelectionView() }
    func updateNSView(_ view: SelectionView, context: Context) { view.attach() }
    static func dismantleNSView(_ view: SelectionView, coordinator: ()) { view.detach() }

    final class SelectionView: NSView {
        @MainActor
        private final class Lease {
            let previous: NSTableView.SelectionHighlightStyle
            var count = 0
            init(_ table: NSTableView) { previous = table.selectionHighlightStyle }
        }
        private static let leases = NSMapTable<NSTableView, Lease>.weakToStrongObjects()
        private weak var table: NSTableView?

        isolated deinit { detach() }

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
            guard let next = enclosingScrollView?.documentView as? NSTableView else {
                detach()
                return
            }
            attach(to: next)
        }

        func attach(to next: NSTableView) {
            guard table !== next else { return }
            detach()
            let lease = Self.leases.object(forKey: next) ?? Lease(next)
            lease.count += 1
            Self.leases.setObject(lease, forKey: next)
            table = next
            if next.selectionHighlightStyle != .none { next.selectionHighlightStyle = .none }
        }

        func detach() {
            guard let table, let lease = Self.leases.object(forKey: table) else { return }
            self.table = nil
            lease.count -= 1
            // Changing table style recycles its rows. Let replacement rows attach before
            // deciding that the appearance owner has gone away, avoiding a reload loop.
            DispatchQueue.main.async { [weak table] in
                guard let table, lease.count == 0, Self.leases.object(forKey: table) === lease else { return }
                Self.leases.removeObject(forKey: table)
                if table.selectionHighlightStyle == .none { table.selectionHighlightStyle = lease.previous }
            }
        }
    }
}
