import SpottyDomain
import SwiftUI

enum MediaDetailHeaderStyle: Equatable {
    case standard
    case playlist
    case album

    var usesLargeHero: Bool { self != .standard }
}

/// Shared artwork-led identity for albums, artists, and playlists.
struct MediaDetailHeader: View {
    let item: CatalogItem
    let description: String
    let detail: String
    let itemCount: String?
    let style: MediaDetailHeaderStyle
    let artists: [CatalogItem]
    let onSelect: ((CatalogItem) -> Void)?
    @State private var availableWidth: CGFloat = 0

    init(
        item: CatalogItem,
        description: String = "",
        detail: String = "",
        itemCount: String? = nil,
        style: MediaDetailHeaderStyle = .standard,
        artists: [CatalogItem] = [],
        onSelect: ((CatalogItem) -> Void)? = nil
    ) {
        self.item = item
        self.description = description
        self.detail = detail
        self.itemCount = itemCount
        self.style = style
        self.artists = artists
        self.onSelect = onSelect
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
            .padding(.top, style.usesLargeHero ? 64 : 20)
            .padding(.bottom, style.usesLargeHero ? 24 : 16)
    }

    @ViewBuilder
    private func headerContent(width: CGFloat) -> some View {
        if style.usesLargeHero {
            largeHeader(width: width)
        } else if width >= CatalogLayout.headerThreshold {
            horizontalHeader(width: width)
        } else {
            compactHeader(width: width)
        }
    }

    @ViewBuilder
    private func largeHeader(width: CGFloat) -> some View {
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
            cornerRadius: item.kind == .artist ? size / 2 : (style.usesLargeHero ? 8 : 10)
        )
        .frame(width: size, height: size)
        .shadow(
            color: .black.opacity(style.usesLargeHero ? 0.26 : 0.24),
            radius: style.usesLargeHero ? 12 : 14,
            y: style.usesLargeHero ? 6 : 7
        )
    }

    @ViewBuilder
    private func detailColumn(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.kind.rawValue)
                .font(.system(size: 14))
                .foregroundStyle(SpottyPalette.textSecondary)

            Text(item.title)
                .font(.system(size: titleFontSize(for: width), weight: .heavy))
                .accessibilityAddTraits(.isHeader)
                .lineLimit(style.usesLargeHero && width >= 700 ? 1 : 2)
                .minimumScaleFactor(
                    style == .album ? 32 / titleFontSize(for: width) : (style.usesLargeHero ? 0.58 : 0.72)
                )
                .allowsTightening(style.usesLargeHero)
                .fixedSize(horizontal: false, vertical: true)

            if !description.isEmpty {
                Text(description)
                    .font(.system(size: 14))
                    .foregroundStyle(SpottyPalette.textSecondary)
                    .lineLimit(2)
            }

            if !supportingText.isEmpty {
                supportingLabel
                    .font(.system(size: 14))
                    .foregroundStyle(SpottyPalette.textSecondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 2)
    }

    private func titleFontSize(for width: CGFloat) -> CGFloat {
        guard style.usesLargeHero else { return 48 }
        return switch width {
        case ..<620: 40
        case ..<840: 64
        default: 96
        }
    }

    private var supportingText: String {
        [item.subtitle, detail, itemCount ?? ""]
            .filter { !$0.isEmpty && $0.caseInsensitiveCompare(item.kind.rawValue) != .orderedSame }
            .joined(separator: " · ")
    }

    @ViewBuilder
    private var supportingLabel: some View {
        if style == .album, !item.subtitle.isEmpty,
            item.subtitle.caseInsensitiveCompare(item.kind.rawValue) != .orderedSame
        {
            let metadata = [detail, itemCount ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    artistCredits
                    Text(metadata.isEmpty ? "" : " · \(metadata)")
                }
                VStack(alignment: .leading, spacing: 4) {
                    artistCredits
                    if !metadata.isEmpty { Text(metadata) }
                }
            }
        } else {
            Text(supportingText)
        }
    }

    private var artistCredits: some View {
        CatalogArtistLinks(
            artists: artists, fallback: item.subtitle, color: SpottyPalette.textPrimary, onSelect: onSelect
        )
        .fontWeight(.bold)
    }
}
