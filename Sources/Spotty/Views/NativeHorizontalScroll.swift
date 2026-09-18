import AppKit
import SwiftUI

/// Own the shelf's scroll view so vertical wheel input continues to the containing page.
struct NativeHorizontalScroll<Content: View>: NSViewRepresentable {
    var scrollState: NativeListScrollState?
    @ViewBuilder let content: Content

    func makeNSView(context: Context) -> NativeHorizontalScrollView {
        NativeHorizontalScrollView(
            content: AnyView(content.environment(\.self, context.environment)), scrollState: scrollState)
    }

    func updateNSView(_ view: NativeHorizontalScrollView, context: Context) {
        view.update(content: AnyView(content.environment(\.self, context.environment)), scrollState: scrollState)
    }

    static func dismantleNSView(_ view: NativeHorizontalScrollView, coordinator: ()) {
        view.detachScrollState()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeHorizontalScrollView, context: Context) -> CGSize? {
        let size = nsView.hostedSize
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }
}

@MainActor
final class NativeHorizontalScrollView: NSScrollView {
    private let hosting: ShelfHostingView
    private var scrollState: NativeListScrollState?
    private var pendingOffset: CGFloat?
    private var restoringOffset = false
    private var forwardsVerticalGesture: Bool?
    private var pendingGestureStart: NSEvent?
    var hostedSize: NSSize { hosting.fittingSize }

    init(content: AnyView, scrollState: NativeListScrollState? = nil) {
        self.scrollState = scrollState
        pendingOffset = scrollState?.offset
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
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: contentView)
    }

    required init?(coder: NSCoder) { nil }
    isolated deinit { NotificationCenter.default.removeObserver(self) }

    func detachScrollState() {
        scrollState = nil
        pendingOffset = nil
    }

    func update(content: AnyView, scrollState: NativeListScrollState? = nil) {
        if scrollState !== self.scrollState { pendingOffset = scrollState?.offset }
        self.scrollState = scrollState
        hosting.rootView = AnyView(content.fixedSize().frame(maxWidth: .infinity, alignment: .leading))
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    override func layout() {
        let requested = pendingOffset
        restoringOffset = true
        defer { restoringOffset = false }
        super.layout()
        let size = hostedSize
        hosting.frame = NSRect(x: 0, y: 0, width: max(contentSize.width, size.width), height: size.height)
        guard contentSize.width > 0, contentSize.height > 0 else { return }
        let offset = min(max(0, requested ?? contentView.bounds.minX), max(0, hosting.frame.width - contentSize.width))
        if contentView.bounds.minX != offset {
            contentView.scroll(to: NSPoint(x: offset, y: 0))
            reflectScrolledClipView(contentView)
        }
        scrollState?.offset = contentView.bounds.minX
        pendingOffset = nil
    }

    @objc private func scrolled() {
        guard !restoringOffset, pendingOffset == nil else { return }
        scrollState?.offset = max(0, contentView.bounds.minX)
    }

    override func scrollWheel(with event: NSEvent) {
        // Choose one responder for the entire gesture, including diagonal changes and momentum.
        if event.phase.contains(.began) || event.phase.contains(.mayBegin)
            || (event.phase.isEmpty && event.momentumPhase.isEmpty)
        {
            forwardsVerticalGesture = nil
            pendingGestureStart = nil
        }
        if forwardsVerticalGesture == nil {
            guard event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 else {
                if event.phase.contains(.began) { pendingGestureStart = event }
                return
            }
            forwardsVerticalGesture =
                !event.modifierFlags.contains(.shift)
                && abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX)
        }
        // A zero-delta begin cannot choose an axis; replay it once the first delta does.
        if let pendingGestureStart {
            deliverWheel(pendingGestureStart)
            self.pendingGestureStart = nil
        }
        deliverWheel(event)
    }

    private func deliverWheel(_ event: NSEvent) {
        if forwardsVerticalGesture == true {
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
