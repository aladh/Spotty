import SwiftUI

/// Paints the artwork-derived hero gradient behind a detail header and its action row, so the
/// tint carries through both before flattening to `SpottyPalette.catalogCanvas` at the track list.
struct DetailHeroBackground<Content: View>: View {
    let artworkURL: URL?
    let content: () -> Content
    @State private var tint: Color?
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
            .task(id: artworkURL) {
                tint = await ArtworkDominantColor.load(from: artworkURL)
            }
    }
}
