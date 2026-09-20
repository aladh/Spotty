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
        CatalogCardButton(isPointerRevealed: isPointerRevealed, action: action.perform) { focused in
            label(action.showsPause, focused)
        }
        .modifier(CatalogPlaybackControl(action: action))
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
