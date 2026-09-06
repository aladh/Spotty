import AppKit

/// Local Space handling runs before a browsing list can consume the key. It never
/// observes other apps or takes Space away from text editing and native controls.
@MainActor
final class PlaybackKeyboardControls {
    private var monitor: Any?
    private let canToggle: () -> Bool
    private let toggle: () -> Void

    init(canToggle: @escaping () -> Bool, toggle: @escaping () -> Void) {
        self.canToggle = canToggle
        self.toggle = toggle
    }

    var isRunning: Bool { monitor != nil }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                let app = NSApplication.shared
                let window = event.window
                let isPlaybackWindow =
                    window != nil && window === app.mainWindow
                    && window === app.keyWindow && window?.attachedSheet == nil && app.modalWindow == nil
                return self?.handle(
                    event, firstResponder: window?.firstResponder, isPlaybackWindow: isPlaybackWindow,
                    focusedRole: (app.accessibilityFocusedUIElement as? NSAccessibilityProtocol)?.accessibilityRole()
                ) == true
            }
            return consumed ? nil : event
        }
    }

    func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    /// Accessibility roles also cover controls hosted inside SwiftUI responders.
    func handle(
        _ event: NSEvent, firstResponder: NSResponder?, isPlaybackWindow: Bool,
        focusedRole: NSAccessibility.Role? = nil
    ) -> Bool {
        guard isRunning, isPlaybackWindow, event.type == .keyDown,
            event.charactersIgnoringModifiers == " ",
            event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift, .function])
        else { return false }
        if firstResponder is NSText { return false }
        if firstResponder is NSControl && !(firstResponder is NSTableView) { return false }
        let controlRoles: Set<NSAccessibility.Role> = [
            .textField, .textArea, .comboBox, .button, .checkBox, .radioButton,
            .slider, .popUpButton, .menuButton, .incrementor, .menuItem,
        ]
        if let focusedRole, controlRoles.contains(focusedRole) { return false }
        guard canToggle() else { return false }
        if !event.isARepeat { toggle() }
        return true
    }
}
