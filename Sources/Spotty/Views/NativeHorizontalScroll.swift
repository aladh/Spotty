import AppKit
import SwiftUI

/// Own the shelf's scroll view so vertical wheel input continues to the containing page.
struct NativeHorizontalScroll<Content: View>: NSViewRepresentable {
    @ViewBuilder let content: Content

    func makeNSView(context: Context) -> NativeHorizontalScrollView {
        NativeHorizontalScrollView(content: AnyView(content.environment(\.self, context.environment)))
    }

    func updateNSView(_ view: NativeHorizontalScrollView, context: Context) {
        view.update(content: AnyView(content.environment(\.self, context.environment)))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeHorizontalScrollView, context: Context) -> CGSize? {
        let size = nsView.hostedSize
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }
}

@MainActor
final class NativeHorizontalScrollView: NSScrollView {
    private let hosting: ShelfHostingView
    private var forwardsVerticalGesture = false
    var hostedSize: NSSize { hosting.fittingSize }

    init(content: AnyView) {
        hosting = ShelfHostingView(
            rootView: AnyView(content.fixedSize().frame(maxWidth: .infinity, alignment: .leading)))
        super.init(frame: .zero)
        drawsBackground = false
        borderType = .noBorder
        hasHorizontalScroller = true
        hasVerticalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .automatic
        hosting.sizingOptions = [.intrinsicContentSize]
        documentView = hosting
    }

    required init?(coder: NSCoder) { nil }

    func update(content: AnyView) {
        hosting.rootView = AnyView(content.fixedSize().frame(maxWidth: .infinity, alignment: .leading))
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    override func layout() {
        super.layout()
        let size = hostedSize
        hosting.frame = NSRect(x: 0, y: 0, width: max(contentSize.width, size.width), height: size.height)
    }

    override func scrollWheel(with event: NSEvent) {
        // Keep zero-delta phase endings and momentum on the same responder as the gesture.
        if event.phase.contains(.began) || (event.phase.isEmpty && event.momentumPhase.isEmpty)
            || event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0
        {
            forwardsVerticalGesture =
                !event.modifierFlags.contains(.shift)
                && abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX)
        }
        if forwardsVerticalGesture {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// The shelf has no SwiftUI scroll gestures; deliver both wheel axes to the owned scroll view.
@MainActor
private final class ShelfHostingView: NSHostingView<AnyView> {
    override func scrollWheel(with event: NSEvent) {
        enclosingScrollView?.scrollWheel(with: event)
    }
}
