import SwiftUI

/// Catalog artwork controls participate in browsing focus even when macOS limits ordinary button Tab stops.
struct CatalogCardButton<Label: View>: View {
    var isPointerRevealed = true
    let action: () -> Void
    @ViewBuilder let label: (Bool) -> Label
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool
    @AccessibilityFocusState private var isAccessibilityFocused: Bool

    private var hasFocus: Bool { isFocused || isAccessibilityFocused }

    var body: some View {
        Button(action: action) { label(hasFocus) }
            .buttonStyle(.plain)
            .allowsHitTesting(isEnabled && (isPointerRevealed || hasFocus))
            .focusable(isEnabled)
            .focused($isFocused)
            .accessibilityFocused($isAccessibilityFocused)
            .background {
                CatalogCardFocusReveal(isFocused: hasFocus)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onKeyPress(.space, phases: CatalogCardKeyHandling.phases) { press in
                CatalogCardKeyHandling.handle(
                    phase: press.phase, modifiers: press.modifiers, isEnabled: isEnabled, action: action)
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
