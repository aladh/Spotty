import AppKit
import SwiftUI

extension View {
    /// Testable geometry belongs to the rendered production surface, never a duplicate test UI.
    @ViewBuilder func shellGeometry(_ identifier: String?) -> some View {
        #if DEBUG || SPOTTY_BROWSING_OPTIMIZED
            if let identifier {
                background(ShellGeometryMarker(identifier: identifier).allowsHitTesting(false))
            } else {
                self
            }
        #else
            self
        #endif
    }
}

#if DEBUG || SPOTTY_BROWSING_OPTIMIZED
    @MainActor
    enum ShellGeometry {
        /// Window base coordinates (bottom-left origin). Only product-owned markers are read.
        static func frames(in window: NSWindow) -> [String: CGRect] {
            var result: [String: CGRect] = [:]
            func visit(_ view: NSView) {
                if let marker = view as? ShellGeometryView, marker.window === window {
                    result[marker.geometryIdentifier] = marker.convert(marker.bounds, to: nil)
                }
                for child in view.subviews { visit(child) }
            }
            if let content = window.contentView { visit(content) }
            for item in window.toolbar?.visibleItems ?? [] {
                if let view = item.view { visit(view) }
            }
            for accessory in window.titlebarAccessoryViewControllers { visit(accessory.view) }
            return result
        }
    }

    private struct ShellGeometryMarker: NSViewRepresentable {
        let identifier: String
        func makeNSView(context: Context) -> ShellGeometryView { ShellGeometryView(identifier: identifier) }
        func updateNSView(_ view: ShellGeometryView, context: Context) { view.geometryIdentifier = identifier }
    }

    private final class ShellGeometryView: NSView {
        var geometryIdentifier: String
        init(identifier: String) {
            geometryIdentifier = identifier
            super.init(frame: .zero)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
#endif
