import CoreGraphics
import SpottyDomain
import SpottyRuntimeContracts
import SwiftUI

struct ArtworkAccess: Sendable {
    let provider: any ArtworkProviding
    let accountEpoch: UInt64

    init(provider: any ArtworkProviding = UnavailableArtworkProvider(), accountEpoch: UInt64 = 0) {
        self.provider = provider
        self.accountEpoch = accountEpoch
    }
}

private struct ArtworkAccessKey: EnvironmentKey {
    static let defaultValue = ArtworkAccess()
}

extension EnvironmentValues {
    var artworkAccess: ArtworkAccess {
        get { self[ArtworkAccessKey.self] }
        set { self[ArtworkAccessKey.self] = newValue }
    }
}

struct RemoteArtwork: View {
    let url: URL?
    let kind: CatalogItem.Kind
    let cornerRadius: CGFloat
    @Environment(\.artworkAccess) private var artwork
    @Environment(\.displayScale) private var displayScale
    @State private var loaded: LoadedArtwork?

    private struct LoadedArtwork {
        let request: ArtworkRequest
        let image: CGImage
    }

    var body: some View {
        GeometryReader { geometry in
            let request = url.map {
                ArtworkRequest(
                    url: $0, maximumPixelDimension: pixelDimension(for: geometry.size),
                    accountEpoch: artwork.accountEpoch)
            }
            Group {
                if let loaded, loaded.request == request {
                    Image(decorative: loaded.image, scale: displayScale)
                        .resizable()
                        .scaledToFill()
                } else {
                    placeholder
                }
            }
            .task(id: request) {
                loaded = nil
                guard let request,
                    let asset = try? await artwork.provider.artwork(for: request),
                    !Task.isCancelled, let image = Self.displayImage(asset)
                else { return }
                loaded = LoadedArtwork(request: request, image: image)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.separator.opacity(0.28))
        }
        .accessibilityHidden(true)
    }

    private func pixelDimension(for size: CGSize) -> Int {
        let value = max(size.width, size.height) * displayScale
        guard value.isFinite else { return 64 }
        let requested = Int(min(1_024, max(64, value.rounded(.up))))
        return [64, 128, 256, 512, 1_024].first { $0 >= requested } ?? 1_024
    }

    /// Binds pixels decoded by the runtime to a native image; no image file is decoded here.
    private static func displayImage(_ asset: ArtworkAsset) -> CGImage? {
        guard asset.pixelWidth > 0, asset.pixelHeight > 0,
            asset.pixelWidth <= 1_024, asset.pixelHeight <= 1_024,
            asset.rgbaPixels.count == asset.pixelWidth * asset.pixelHeight * 4,
            let provider = CGDataProvider(data: asset.rgbaPixels as CFData),
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGImage(
            width: asset.pixelWidth, height: asset.pixelHeight, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: asset.pixelWidth * 4, space: colorSpace,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
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
