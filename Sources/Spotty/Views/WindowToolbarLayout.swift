import AppKit
import SwiftUI

/// Own the full native titlebar accessory instead of depending on SwiftUI's
/// toolbar icon baseline. Its hosted controls and their hit bounds stay together.
struct WindowToolbarLayout<History: View, Navigation: View>: NSViewRepresentable {
    let history: History
    let navigation: Navigation

    func makeNSView(context: Context) -> ToolbarLayoutView {
        ToolbarLayoutView(
            history: AnyView(history.environment(\.self, context.environment)),
            navigation: AnyView(navigation.environment(\.self, context.environment)))
    }

    func updateNSView(_ view: ToolbarLayoutView, context: Context) {
        view.accessoryView.historyHost.rootView = AnyView(history.environment(\.self, context.environment))
        view.accessoryView.navigationHost.rootView = AnyView(navigation.environment(\.self, context.environment))
        view.install()
        view.resizeAccessory()
        view.accessoryView.needsLayout = true
    }

    static func dismantleNSView(_ view: ToolbarLayoutView, coordinator: ()) { view.uninstall() }

    final class ToolbarLayoutView: NSView {
        let accessoryView: AccessoryView
        private let accessory = NSTitlebarAccessoryViewController()
        private let toolbar = NSToolbar(identifier: "spotty.navigation")
        private weak var installedWindow: NSWindow?
        private var previousToolbar: NSToolbar?

        init(history: AnyView, navigation: AnyView) {
            accessoryView = AccessoryView(history: history, navigation: navigation)
            super.init(frame: .zero)
            accessory.layoutAttribute = .right
            accessory.view = accessoryView
            toolbar.displayMode = .iconAndLabel
            // The fixed Spotify controls have no alternate icon/text presentation.
            toolbar.allowsDisplayModeCustomization = false
            toolbar.allowsUserCustomization = false
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if installedWindow !== window { uninstall() }
            install()
        }

        func install() {
            guard let window, window.styleMask.contains(.titled), installedWindow !== window else { return }
            installedWindow = window
            previousToolbar = window.toolbar
            window.toolbar = toolbar
            resizeAccessory()
            window.addTitlebarAccessoryViewController(accessory)
            for name in [NSWindow.didResizeNotification, NSWindow.didUpdateNotification] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(windowDidUpdate(_:)), name: name, object: window)
            }
        }

        @objc private func windowDidUpdate(_: Notification) { resizeAccessory() }

        func resizeAccessory() {
            guard let window = installedWindow, let content = window.contentView else { return }
            // The leading native window-control area stays with AppKit. All
            // navigation is inside the accessory's actual allocated rectangle.
            let leading =
                [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
                .compactMap { window.standardWindowButton($0) }
                .map { $0.convert($0.bounds, to: nil).maxX }
                .max().map { $0 + 13 } ?? 91
            let width = max(0, content.bounds.width - leading)
            if abs(accessoryView.frame.width - width) > 0.25 {
                accessoryView.setFrameSize(CGSize(width: width, height: 66))
                accessoryView.needsLayout = true
            }
        }

        func uninstall() {
            NotificationCenter.default.removeObserver(self)
            if let window = installedWindow {
                if let index = window.titlebarAccessoryViewControllers.firstIndex(where: { $0 === accessory }) {
                    window.removeTitlebarAccessoryViewController(at: index)
                }
                if window.toolbar === toolbar { window.toolbar = previousToolbar }
            }
            installedWindow = nil
            previousToolbar = nil
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    final class AccessoryView: NSView {
        let historyHost: NSHostingView<AnyView>
        let navigationHost: NSHostingView<AnyView>

        init(history: AnyView, navigation: AnyView) {
            historyHost = NSHostingView(rootView: history)
            navigationHost = NSHostingView(rootView: navigation)
            super.init(frame: CGRect(x: 0, y: 0, width: 1124, height: 66))
            historyHost.sizingOptions = [.intrinsicContentSize]
            navigationHost.sizingOptions = [.intrinsicContentSize]
            addSubview(historyHost)
            addSubview(navigationHost)
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            guard let window, let content = window.contentView else { return }
            let windowRect = content.convert(content.bounds, to: nil)
            let center = convert(CGPoint(x: windowRect.midX, y: windowRect.maxY - 32), from: nil)
            let navigationSize = navigationHost.fittingSize
            let historySize = historyHost.fittingSize
            navigationHost.frame = CGRect(
                x: center.x - navigationSize.width / 2, y: center.y - navigationSize.height / 2,
                width: navigationSize.width, height: navigationSize.height)
            historyHost.frame = CGRect(
                x: 0, y: center.y - historySize.height / 2,
                width: historySize.width, height: historySize.height)
        }

        // Only the two owned control surfaces receive input; empty native chrome
        // keeps AppKit's window dragging and double-click behavior.
        override func hitTest(_ point: NSPoint) -> NSView? {
            let result = super.hitTest(point)
            return result === self ? nil : result
        }
    }
}
