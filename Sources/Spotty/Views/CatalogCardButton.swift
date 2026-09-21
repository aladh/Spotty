import SwiftUI

/// Catalog artwork controls participate in browsing focus even when macOS limits ordinary button Tab stops.
struct CatalogCardButton<Label: View>: View {
    var isPointerRevealed = true
    var isPlaybackAvailable: Bool?
    let action: () -> Void
    @ViewBuilder let label: (Bool) -> Label
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.nativeRowFocusTarget) private var nativeRowFocusTarget
    @FocusState private var isFocused: Bool
    @AccessibilityFocusState private var isAccessibilityFocused: Bool

    private var hasFocus: Bool { isFocused || isAccessibilityFocused }

    var body: some View {
        let button = Button(action: action) { label(hasFocus) }
        Group {
            if let isPlaybackAvailable {
                button.buttonStyle(PlaybackControlButtonStyle(isAvailable: isPlaybackAvailable))
            } else {
                button.buttonStyle(.plain)
            }
        }
        .allowsHitTesting(isEnabled && (isPointerRevealed || hasFocus))
        .focusable(isEnabled)
        .focused($isFocused)
        .accessibilityFocused($isAccessibilityFocused)
        .background {
            CatalogCardFocusReveal(
                isFocused: hasFocus, isKeyboardFocused: isFocused,
                requestKeyboardFocus: {
                    guard isEnabled, !isFocused else { return false }
                    isFocused = true
                    return true
                }
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .onKeyPress(.space, phases: CatalogCardKeyHandling.phases) { press in
            CatalogCardKeyHandling.handle(
                phase: press.phase, modifiers: press.modifiers, isEnabled: isEnabled, action: action)
        }
        .onKeyPress(phases: .down) { press in
            // AppKit reports Shift-Tab as backtab rather than a tab character.
            guard isFocused, press.key == .tab || press.key.character == "\u{19}",
                press.modifiers.subtracting([.shift, .capsLock]).isEmpty,
                let nativeRowFocusTarget
            else { return .ignored }
            // Native responder movement clears SwiftUI focus; clearing it first can undo that movement.
            return nativeRowFocusTarget.leaveControl(backwards: press.modifiers.contains(.shift))
                ? .handled : .ignored
        }
    }
}

/// Own every Space phase so a native button cannot also activate on release.
enum CatalogCardKeyHandling {
    static let phases: KeyPress.Phases = [.down, .repeat, .up]

    static func handle(
        phase: KeyPress.Phases, modifiers: EventModifiers, isEnabled: Bool, action: () -> Void
    ) -> KeyPress.Result {
        guard isEnabled, modifiers.subtracting(.capsLock).isEmpty else { return .ignored }
        if phase == .down { action() }
        return .handled
    }
}
