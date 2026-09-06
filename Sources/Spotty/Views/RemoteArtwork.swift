import SpottyDomain
import SwiftUI

struct RemoteArtwork: View {
    let url: URL?
    let kind: CatalogItem.Kind
    let cornerRadius: CGFloat
    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.separator.opacity(0.28))
        }
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: SpottyPalette.artworkPlaceholderColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: symbol)
                .font(.title2.weight(.medium))
                .foregroundStyle(SpottyPalette.textSecondary)
        }
    }

    private var symbol: String {
        switch kind {
        case .album: "square.stack.fill"
        case .artist: "music.mic"
        case .playlist: "music.note.list"
        case .track: "music.note"
        case .unknown: "waveform"
        }
    }
}
