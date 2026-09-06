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
                    event, firstResponder: window?.firstResponder, isPlaybackWindow: isPlaybackWindow
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

    /// Returns whether the event was consumed, including repeats and unavailable
    /// playback, so holding Space can never toggle repeatedly or fall through.
    func handle(_ event: NSEvent, firstResponder: NSResponder?, isPlaybackWindow: Bool) -> Bool {
        guard isRunning, isPlaybackWindow, event.type == .keyDown,
            event.charactersIgnoringModifiers == " ",
            event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        else { return false }
        if firstResponder is NSText { return false }
        if firstResponder is NSControl && !(firstResponder is NSTableView) { return false }
        if !event.isARepeat && canToggle() { toggle() }
        return true
    }
}
