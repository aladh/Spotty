import SpottyDomain
import SwiftUI

enum MediaDetailHeaderStyle: Equatable {
    case standard
    case playlist
}

/// Shared artwork-led identity for albums, artists, and playlists.
struct MediaDetailHeader: View {
    let item: CatalogItem
    let description: String
    let detail: String
    let itemCount: String?
    let canPlay: Bool
    let play: () -> Void
    let style: MediaDetailHeaderStyle
    @State private var availableWidth: CGFloat = 0

    init(
        item: CatalogItem,
        description: String = "",
        detail: String = "",
        itemCount: String? = nil,
        canPlay: Bool = false,
        style: MediaDetailHeaderStyle = .standard,
        play: @escaping () -> Void = {}
    ) {
        self.item = item
        self.description = description
        self.detail = detail
        self.itemCount = itemCount
        self.canPlay = canPlay
        self.style = style
        self.play = play
    }

    var body: some View {
        headerContent(width: availableWidth)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { newWidth in
                guard newWidth > 0 else { return }
                availableWidth = newWidth
            }
            .padding(.horizontal, CatalogLayout.contentPadding)
            .padding(.top, style == .playlist ? 64 : 20)
            .padding(.bottom, style == .playlist ? 24 : 16)
            .background {
                if style == .playlist {
                    LinearGradient(
                        colors: SpottyPalette.playlistHeroGradient,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .ignoresSafeArea(edges: .horizontal)
                }
            }
    }

    @ViewBuilder
    private func headerContent(width: CGFloat) -> some View {
        if style == .playlist {
            playlistHeader(width: width)
        } else if width >= CatalogLayout.headerThreshold {
            horizontalHeader(width: width)
        } else {
            compactHeader(width: width)
        }
    }

    @ViewBuilder
    private func playlistHeader(width: CGFloat) -> some View {
        if width >= 600 {
            HStack(alignment: .bottom, spacing: 24) {
                artwork(size: width >= 1000 ? 232 : 192)
                detailColumn(width: width)
                Spacer(minLength: 0)
            }
        } else {
            VStack(alignment: .leading, spacing: 16) {
                artwork(size: min(192, max(128, width - (CatalogLayout.contentPadding * 2))))
                detailColumn(width: width)
            }
        }
    }

    private func horizontalHeader(width: CGFloat) -> some View {
        return HStack(alignment: .bottom, spacing: 26) {
            artwork(size: horizontalArtworkSize(for: width))
            detailColumn(width: width)
            Spacer(minLength: 0)
        }
    }

    private func compactHeader(width: CGFloat) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 20) {
                artwork(size: compactArtworkSize(for: width))
                detailColumn(width: width)
            }

            VStack(alignment: .leading, spacing: 18) {
                artwork(size: compactArtworkSize(for: width))
                detailColumn(width: width)
            }
        }
    }

    private func horizontalArtworkSize(for width: CGFloat) -> CGFloat {
        switch width {
        case ..<820:
            return CatalogLayout.headerMinimumArtwork
        case ..<940:
            return CatalogLayout.headerMediumArtwork
        default:
            return CatalogLayout.headerMaximumArtwork
        }
    }

    private func compactArtworkSize(for width: CGFloat) -> CGFloat {
        width < 560 ? CatalogLayout.headerCompactArtwork : CatalogLayout.headerMinimumArtwork
    }

    private func artwork(size: CGFloat) -> some View {
        RemoteArtwork(
            url: item.artworkURL,
            kind: item.kind,
            cornerRadius: item.kind == .artist ? size / 2 : (style == .playlist ? 8 : 10),
            pointSize: size
        )
        .frame(width: size, height: size)
        .shadow(
            color: .black.opacity(style == .playlist ? 0.26 : 0.24),
            radius: style == .playlist ? 12 : 14,
            y: style == .playlist ? 6 : 7
        )
    }

    @ViewBuilder
    private func detailColumn(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.kind.rawValue)
                .font(.system(size: 14))
                .foregroundStyle(SpottyPalette.textSecondary)

            Text(item.title)
                .font(titleFont(for: width))
                .accessibilityAddTraits(.isHeader)
                .lineLimit(style == .playlist && width >= 700 ? 1 : 2)
                .minimumScaleFactor(style == .playlist ? 0.58 : 0.72)
                .allowsTightening(style == .playlist)
                .fixedSize(horizontal: false, vertical: true)

            if !description.isEmpty {
                Text(description)
                    .font(.system(size: 14))
                    .foregroundStyle(SpottyPalette.textSecondary)
                    .lineLimit(2)
            }

            if !supportingText.isEmpty {
                Text(supportingText)
                    .font(.system(size: 14))
                    .foregroundStyle(SpottyPalette.textSecondary)
                    .lineLimit(2)
            }

            if style == .standard {
                CircularPlayButton(action: play, isEnabled: canPlay)
                    .accessibilityHint("Starts this \(item.kind.rawValue.lowercased())")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 2)
    }

    private func titleFont(for width: CGFloat) -> Font {
        guard style == .playlist else { return .system(size: 48, weight: .heavy) }
        let size: CGFloat =
            switch width {
            case ..<620: 40
            case ..<840: 64
            default: 96
            }
        return .system(size: size, weight: .heavy)
    }

    private var supportingText: String {
        [item.subtitle, detail, itemCount ?? ""]
            .filter { !$0.isEmpty && $0.caseInsensitiveCompare(item.kind.rawValue) != .orderedSame }
            .joined(separator: " · ")
    }
}
