import SwiftUI
import SpottyRuntimeContracts

/// Paints the artwork-derived hero gradient behind a detail header and its action row, so the
/// tint carries through both before flattening to `SpottyPalette.catalogCanvas` at the track list.
struct DetailHeroBackground<Content: View>: View {
    let artworkURL: URL?
    let content: () -> Content
    @State private var loadedTint: (request: ArtworkRequest, color: Color)?
    @Environment(\.artworkAccess) private var artwork

    private var tintRequest: ArtworkRequest? {
        artworkURL.map { ArtworkRequest(url: $0, maximumPixelDimension: 64, accountEpoch: artwork.accountEpoch) }
    }

    private var tint: Color? { loadedTint?.request == tintRequest ? loadedTint?.color : nil }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(artworkURL: URL?, @ViewBuilder content: @escaping () -> Content) {
        self.artworkURL = artworkURL
        self.content = content
    }

    var body: some View {
        content()
            .background {
                LinearGradient(
                    colors: [tint ?? SpottyPalette.playlistHeroGradient[0], SpottyPalette.catalogCanvas],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea(edges: .horizontal)
                .animationIfAllowed(.easeInOut(duration: 0.35), value: tint, reduceMotion: reduceMotion)
            }
            .task(id: tintRequest) {
                loadedTint = nil
                guard let request = tintRequest,
                    let loaded = try? await ArtworkDominantColor.load(from: artworkURL, using: artwork)
                else { return }
                guard !Task.isCancelled else { return }
                loadedTint = (request, loaded)
            }
    }
}
