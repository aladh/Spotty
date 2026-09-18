import AppKit
import SwiftUI

private struct NativeRowFocusTargetKey: EnvironmentKey {
    static let defaultValue: NativeRowFocusTarget? = nil
}

extension EnvironmentValues {
    var nativeRowFocusTarget: NativeRowFocusTarget? {
        get { self[NativeRowFocusTargetKey.self] }
        set { self[NativeRowFocusTargetKey.self] = newValue }
    }
}

/// An owned table cell connects Tab to its SwiftUI control without assuming the window key loop includes hosted rows.
@MainActor
final class NativeRowFocusTarget {
    weak var control: CatalogCardFocusView?
    weak var table: NSTableView?
    weak var host: NSView?

    private var ownedControl: CatalogCardFocusView? {
        guard let control, let host, let window = table?.window,
            host.window === window, control.window === window, control.isDescendant(of: host)
        else { return nil }
        return control
    }

    func focus() -> Bool { ownedControl?.requestKeyboardFocus() ?? false }

    func leaveControl(backwards: Bool) -> Bool {
        guard let table, let window = table.window, ownedControl != nil else { return false }
        if backwards {
            return window.makeFirstResponder(table)
        }
        let previous = window.firstResponder
        window.selectKeyView(following: table)
        return window.firstResponder !== previous
    }
}

/// An owned geometry anchor reveals focus through both the shelf and the containing page.
struct CatalogCardFocusReveal: NSViewRepresentable {
    let isFocused: Bool
    var requestKeyboardFocus: (() -> Bool)?
    @Environment(\.nativeRowFocusTarget) private var focusTarget

    func makeNSView(context: Context) -> CatalogCardFocusView { CatalogCardFocusView() }

    func updateNSView(_ view: CatalogCardFocusView, context: Context) {
        view.registerFocus(target: focusTarget, request: requestKeyboardFocus)
        view.updateFocus(isFocused)
    }

    static func dismantleNSView(_ view: CatalogCardFocusView, coordinator: ()) {
        view.registerFocus(target: nil, request: nil)
    }
}

@MainActor
final class CatalogCardFocusView: NSView {
    private var isFocused = false
    private var needsReveal = false
    private weak var focusTarget: NativeRowFocusTarget?
    private var keyboardFocusRequest: (() -> Bool)?

    func registerFocus(target: NativeRowFocusTarget?, request: (() -> Bool)?) {
        if focusTarget !== target, focusTarget?.control === self { focusTarget?.control = nil }
        focusTarget = target
        target?.control = self
        keyboardFocusRequest = request
    }

    func requestKeyboardFocus() -> Bool {
        guard window != nil, !bounds.isEmpty, let keyboardFocusRequest else { return false }
        return keyboardFocusRequest()
    }

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

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        let didMove = frame.origin != newOrigin
        super.setFrameOrigin(newOrigin)
        if didMove && isFocused { needsReveal = true }
        revealIfReady()
    }

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        let didMove = bounds.origin != newOrigin
        super.setBoundsOrigin(newOrigin)
        if didMove && isFocused { needsReveal = true }
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
