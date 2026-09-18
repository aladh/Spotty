import SpottyDomain
import SwiftUI

/// Keep the native control present for keyboard and accessibility access; only its artwork fades.
struct CatalogCardPlayButton: View {
    let item: CatalogItem
    let playback: CatalogPlaybackAccess
    let isHovering: Bool
    var diameter: CGFloat = 48

    var body: some View {
        CatalogCardButton {
            if item.kind == .playlist {
                playback.playPlaylist(item)
            } else {
                playback.playURI(item.uri)
            }
        } label: { isFocused in
            let isRevealed = isHovering || isFocused
            Circle()
                .fill(SpottyPalette.mediaGreen)
                .frame(width: diameter, height: diameter)
                .overlay {
                    TransportSymbol(kind: .play)
                        .frame(width: diameter / 2, height: diameter / 2)
                        .foregroundStyle(.black)
                }
                .opacity(isRevealed ? (playback.canStartPlayback ? 1 : 0.4) : 0)
                .contentShape(Circle())
                .animation(.easeOut(duration: 0.15), value: isRevealed)
        }
        .disabled(!playback.canStartPlayback)
        .pointingHandCursor(enabled: playback.canStartPlayback)
        .accessibilityLabel("Play \(item.title)")
        .help("Play \(item.title)")
    }
}
