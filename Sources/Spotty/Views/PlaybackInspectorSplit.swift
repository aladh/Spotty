import AppKit
import SwiftUI

/// Own the inspector split so opening it cannot partition the native toolbar.
/// The pane keeps AppKit resizing and its last width while commands share the
/// scene's presentation binding.
struct PlaybackInspectorSplit<Content: View, Inspector: View>: NSViewControllerRepresentable {
    let isPresented: Bool
    @ViewBuilder let content: Content
    @ViewBuilder let inspector: Inspector

    func makeNSViewController(context: Context) -> Controller {
        Controller(
            content: AnyView(content.environment(\.self, context.environment)),
            inspector: AnyView(inspector.environment(\.self, context.environment)), isPresented: isPresented)
    }

    func updateNSViewController(_ controller: Controller, context: Context) {
        controller.contentHost.rootView = AnyView(content.environment(\.self, context.environment))
        controller.inspectorHost.rootView = AnyView(inspector.environment(\.self, context.environment))
        controller.setPresented(isPresented)
    }

    final class Controller: NSSplitViewController {
        let contentHost: NSHostingController<AnyView>
        let inspectorHost: NSHostingController<AnyView>
        private let inspectorItem: NSSplitViewItem
        private var needsInitialWidth = true

        init(content: AnyView, inspector: AnyView, isPresented: Bool) {
            contentHost = NSHostingController(rootView: content)
            inspectorHost = NSHostingController(rootView: inspector)
            inspectorItem = NSSplitViewItem(viewController: inspectorHost)
            super.init(nibName: nil, bundle: nil)
            splitView.isVertical = true
            splitView.dividerStyle = .thin
            addSplitViewItem(NSSplitViewItem(viewController: contentHost))
            inspectorItem.minimumThickness = 260
            inspectorItem.maximumThickness = 360
            // Preserve the pane before the content's default 250 priority on a
            // window resize, without overriding AppKit's divider tracking.
            inspectorItem.holdingPriority = .init(rawValue: 251)
            inspectorItem.canCollapse = false
            addSplitViewItem(inspectorItem)
            inspectorItem.isCollapsed = !isPresented
        }

        required init?(coder: NSCoder) { nil }

        func setPresented(_ isPresented: Bool) {
            guard inspectorItem.isCollapsed == isPresented else { return }
            inspectorItem.isCollapsed = !isPresented
            view.needsLayout = true
        }

        override func viewDidLayout() {
            super.viewDidLayout()
            guard needsInitialWidth, !inspectorItem.isCollapsed, splitView.bounds.width > 0 else { return }
            needsInitialWidth = false
            splitView.setPosition(splitView.bounds.width - 280 - splitView.dividerThickness, ofDividerAt: 0)
        }
    }
}
