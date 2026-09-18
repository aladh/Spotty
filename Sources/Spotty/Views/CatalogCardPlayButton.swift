import SpottyDomain
import SwiftUI

/// Keep the native control present for keyboard and accessibility access; only its artwork fades.
struct CatalogCardPlayButton: View {
    let item: CatalogItem
    let playback: CatalogPlaybackAccess
    let isHovering: Bool
    var diameter: CGFloat = 48

    var body: some View {
        CatalogCardButton(isPointerRevealed: isHovering) {
            playback.activateItem(item)
        } label: { isFocused in
            let isRevealed = isHovering || isFocused
            Circle()
                .fill(SpottyPalette.mediaGreen)
                .frame(width: diameter, height: diameter)
                .overlay {
                    TransportSymbol(kind: playback.showsPause(for: item) ? .pause : .play)
                        .frame(width: diameter / 2, height: diameter / 2)
                        .foregroundStyle(.black)
                }
                .opacity(isRevealed ? (playback.canActivateItem(item) ? 1 : 0.4) : 0)
                .contentShape(Circle())
                .animation(.easeOut(duration: 0.15), value: isRevealed)
        }
        .disabled(!playback.canActivateItem(item))
        .pointingHandCursor(enabled: playback.canActivateItem(item))
        .accessibilityLabel(playback.activationLabel(for: item))
        .help(playback.activationLabel(for: item))
    }
}
