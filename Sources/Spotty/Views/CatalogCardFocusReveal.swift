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

    func focus() -> Bool {
        guard ownedControl?.requestKeyboardFocus() == true else { return false }
        // Commit the hosted FocusState before another key can traverse past its pending destination.
        host?.layoutSubtreeIfNeeded()
        return true
    }

    func leaveControl(backwards: Bool) -> Bool {
        guard let table, let window = table.window, ownedControl != nil else { return false }
        let previous = window.firstResponder
        if backwards {
            return window.makeFirstResponder(table) && window.firstResponder !== previous
        }
        window.selectKeyView(following: table)
        return window.firstResponder !== previous
    }
}

/// An owned geometry anchor reveals focus through both the shelf and the containing page.
struct CatalogCardFocusReveal: NSViewRepresentable {
    let isFocused: Bool
    var isKeyboardFocused = false
    var requestKeyboardFocus: (() -> Bool)?
    @Environment(\.nativeRowFocusTarget) private var focusTarget
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> CatalogCardFocusView { CatalogCardFocusView() }

    func updateNSView(_ view: CatalogCardFocusView, context: Context) {
        view.registerFocus(target: focusTarget, request: requestKeyboardFocus)
        view.updateKeyboardFocus(isEnabled: isEnabled, isFocused: isKeyboardFocused)
        view.updateFocus(isFocused)
    }

    static func dismantleNSView(_ view: CatalogCardFocusView, coordinator: ()) {
        view.registerFocus(target: nil, request: nil)
    }
}

@MainActor
final class CatalogCardFocusView: NSView {
    private var isFocused = false
    private var isEnabled = true
    private var isKeyboardFocused = false
    private var isKeyboardFocusPending = false
    private var needsReveal = false
    private weak var focusTarget: NativeRowFocusTarget?
    private var keyboardFocusRequest: (() -> Bool)?

    func registerFocus(target: NativeRowFocusTarget?, request: (() -> Bool)?) {
        if focusTarget !== target {
            if focusTarget?.control === self { focusTarget?.control = nil }
            isKeyboardFocusPending = false
        }
        if request == nil { isKeyboardFocusPending = false }
        focusTarget = target
        target?.control = self
        keyboardFocusRequest = request
    }

    func updateKeyboardFocus(isEnabled: Bool, isFocused: Bool) {
        self.isEnabled = isEnabled
        isKeyboardFocused = isFocused
        if !isEnabled || isFocused { isKeyboardFocusPending = false }
    }

    func requestKeyboardFocus() -> Bool {
        guard isEnabled, !isKeyboardFocused, !isKeyboardFocusPending,
            window != nil, !bounds.isEmpty, let keyboardFocusRequest
        else { return false }
        // SwiftUI commits FocusState later; a second Tab must not consume the same request.
        isKeyboardFocusPending = true
        let accepted = keyboardFocusRequest()
        if !accepted { isKeyboardFocusPending = false }
        return accepted
    }

    func updateFocus(_ focused: Bool) {
        guard isFocused != focused else { return }
        isFocused = focused
        needsReveal = focused
        revealIfReady()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { isKeyboardFocusPending = false }
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
