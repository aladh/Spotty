import AppKit
import SpottyDomain
import SwiftUI

struct RemoteArtwork: View {
    let url: URL?
    let kind: CatalogItem.Kind
    let cornerRadius: CGFloat
    let pointSize: CGFloat

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
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
        .task(id: cacheKey) {
            await loadImage()
        }
        // List rows retain their SwiftUI state after recycling. Releasing this strong reference
        // lets the bounded NSCache actually evict artwork during long scrolling sessions.
        .onDisappear { image = nil }
    }

    private var cacheKey: String { "\(url?.absoluteString ?? "")#\(pointSize)" }

    private func loadImage() async {
        image = nil
        guard let url else { return }
        let decoded = await ArtworkCache.shared.image(for: url, pointSize: pointSize)
        // Cancellation does not stop the shared fetch from answering; the row
        // must not adopt what an earlier identity asked for.
        guard !Task.isCancelled else { return }
        image = decoded
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
