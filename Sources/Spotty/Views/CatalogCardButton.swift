import SwiftUI

/// Catalog cards participate in browsing focus, including when macOS limits ordinary button Tab stops.
struct CatalogCardButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: (Bool) -> Label
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool
    @AccessibilityFocusState private var isAccessibilityFocused: Bool

    private var hasFocus: Bool { isFocused || isAccessibilityFocused }

    var body: some View {
        Button(action: action) { label(hasFocus) }
            .buttonStyle(.plain)
            .focusable(isEnabled)
            .focused($isFocused)
            .accessibilityFocused($isAccessibilityFocused)
            .background {
                CatalogCardFocusReveal(isFocused: hasFocus)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onKeyPress(.space, phases: [.down, .repeat]) { press in
                guard isEnabled, press.modifiers.subtracting(.capsLock).isEmpty
                else { return .ignored }
                if press.phase == .down { action() }
                return .handled
            }
    }
}
