import SwiftUI

/// The semantic action supplies both presentation and dispatch; callers own only appearance.
struct CatalogPlaybackButton<Label: View>: View {
    let action: CatalogPlaybackAction
    @ViewBuilder let label: (Bool) -> Label

    var body: some View {
        CatalogArtworkPlaybackButton(action: action) { showsPause, _ in label(showsPause) }
    }
}

/// Artwork controls share native focus, one activation per Space, and accessibility at rest.
struct CatalogArtworkPlaybackButton<Label: View>: View {
    let action: CatalogPlaybackAction
    var isPointerRevealed = true
    @ViewBuilder let label: (Bool, Bool) -> Label

    var body: some View {
        CatalogCardButton(
            isPointerRevealed: isPointerRevealed, isPlaybackAvailable: action.isAvailable, action: action.perform
        ) { focused in
            label(action.showsPause, focused)
        }
        .modifier(CatalogPlaybackControl(action: action))
    }
}

/// Preserve resting colors through the brief input fence of an in-flight playback command.
/// Native disabled semantics still own mouse, keyboard, and accessibility admission.
struct PlaybackControlButtonStyle: ButtonStyle {
    let isAvailable: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(isAvailable ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
}

private struct CatalogPlaybackControl: ViewModifier {
    let action: CatalogPlaybackAction

    func body(content: Content) -> some View {
        content
            .disabled(!action.isEnabled)
            .pointingHandCursor(enabled: action.isEnabled)
            .accessibilityLabel(action.label)
            .help(action.label)
    }
}
