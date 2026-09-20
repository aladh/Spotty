import SpottyDomain
import SwiftUI

/// Keep the native control present for keyboard and accessibility access; only its artwork fades.
struct CatalogCardPlayButton: View {
    let item: CatalogItem
    let playback: CatalogPlaybackAccess
    let isHovering: Bool
    var diameter: CGFloat = 48

    var body: some View {
        let action = playback.action(for: item, behavior: .activateSelection)
        CatalogArtworkPlaybackButton(action: action, isPointerRevealed: isHovering) { showsPause, isFocused in
            let isRevealed = isHovering || isFocused
            Circle()
                .fill(SpottyPalette.mediaGreen)
                .frame(width: diameter, height: diameter)
                .overlay {
                    TransportSymbol(kind: showsPause ? .pause : .play)
                        .frame(width: diameter / 2, height: diameter / 2)
                        .foregroundStyle(.black)
                }
                .opacity(isRevealed ? (action.isEnabled ? 1 : 0.4) : 0)
                .contentShape(Circle())
                .animation(.easeOut(duration: 0.15), value: isRevealed)
        }
    }
}
