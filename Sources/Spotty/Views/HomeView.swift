import SpottyDomain
import SwiftUI

enum HomeSectionPresentation: Equatable {
    case quickAccess
    case shelf
}

func homeSectionPresentation(at index: Int) -> HomeSectionPresentation {
    index == 0 ? .quickAccess : .shelf
}

struct HomeView: View {
    let store: HomeLibraryStore
    let playback: CatalogPlaybackAccess
    let onSelect: (CatalogItem) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                CatalogContentState(
                    isLoading: store.isLoading(.home), isEmpty: store.homeSections.isEmpty,
                    error: store.error(for: .home), loadingLabel: "Loading your Spotify home",
                    errorTitle: "Couldn't load Spotify Home", connection: playback,
                    connectionIcon: "music.note.house", connectionTitle: "Your music will appear here",
                    disconnectOverridesContent: true,
                    retry: { await store.loadHome(force: true) }
                ) {
                    EmptyState(
                        icon: "rectangle.stack", title: "Spotify Home is empty",
                        message: "Spotify didn't return any recommendations.")
                } content: {
                    HStack {
                        Text(store.greeting)
                            .font(.system(size: 32, weight: .bold))
                        Spacer()
                        if store.isLoading(.home) {
                            ProgressView()
                                .controlSize(.small)
                                .help("Refreshing Spotify")
                        }
                    }

                    ForEach(CatalogDisplayOccurrence.identifying(store.homeSections)) { section in
                        switch homeSectionPresentation(at: section.index) {
                        case .quickAccess:
                            QuickAccessShelf(section: section.element, playback: playback, onSelect: onSelect)
                        case .shelf:
                            MediaShelf(section: section.element, playback: playback, onSelect: onSelect)
                        }
                    }
                }
            }
            .padding(.horizontal, CatalogLayout.contentPadding)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .navigationTitle("Home")
    }
}

struct QuickAccessShelf: View {
    let section: CatalogSection
    let playback: CatalogPlaybackAccess
    let onSelect: (CatalogItem) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 220, maximum: 340), spacing: 10)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.title)
                .font(.system(size: 24, weight: .bold))

            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(CatalogDisplayOccurrence.identifying(Array(section.items.prefix(8)))) { occurrence in
                    QuickAccessCard(item: occurrence.element, playback: playback) { onSelect(occurrence.element) }
                }
            }
        }
    }
}

private struct QuickAccessCard: View {
    let item: CatalogItem
    let playback: CatalogPlaybackAccess
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        CatalogCardButton(action: action) { _ in
            HStack(spacing: 12) {
                RemoteArtwork(
                    url: item.artworkURL,
                    kind: item.kind,
                    cornerRadius: item.kind == .artist ? 28 : 4
                )
                .frame(width: 56, height: 56)

                Text(item.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(
                        playback.isPlayingPlaylist(item.uri) ? SpottyPalette.mediaGreen : SpottyPalette.textPrimary
                    )
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.trailing, 56)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(
                SpottyPalette.quickAccessSurface(isHovering: isHovering),
                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .pointingHandCursor()
        .help(item.kind == .track ? "Play \(item.title)" : "Open \(item.title)")
        .accessibilityLabel(item.title)
        .accessibilityHint(item.kind == .track ? "Starts playback" : "Opens details")
        .overlay(alignment: .trailing) {
            CatalogCardPlayButton(item: item, playback: playback, isHovering: isHovering, diameter: 40)
                .padding(.trailing, 8)
        }
        .hoverSurface(isHovering: $isHovering)
    }
}

struct MediaShelf: View {
    let section: CatalogSection
    let playback: CatalogPlaybackAccess
    var titleLineLimit = 1
    let onSelect: (CatalogItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(section.title)
                .font(.system(size: 24, weight: .bold))
                .accessibilityAddTraits(.isHeader)

            MediaCardRow(items: section.items, playback: playback, titleLineLimit: titleLineLimit, onSelect: onSelect)
        }
    }
}

struct MediaCardRow: View {
    let items: [CatalogItem]
    let playback: CatalogPlaybackAccess
    var titleLineLimit = 1
    let onSelect: (CatalogItem) -> Void

    var body: some View {
        NativeHorizontalScroll {
            HStack(alignment: .top, spacing: 12) {
                ForEach(CatalogDisplayOccurrence.identifying(items)) { occurrence in
                    MediaCard(item: occurrence.element, playback: playback, titleLineLimit: titleLineLimit) {
                        onSelect(occurrence.element)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}

struct MediaCard: View {
    let item: CatalogItem
    let playback: CatalogPlaybackAccess
    var titleLineLimit = 1
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        CatalogCardButton(action: action) { _ in
            VStack(alignment: .leading, spacing: 8) {
                RemoteArtwork(
                    url: item.artworkURL,
                    kind: item.kind,
                    cornerRadius: item.kind == .artist ? CatalogLayout.cardArtwork / 2 : 4
                )
                .frame(width: CatalogLayout.cardArtwork, height: CatalogLayout.cardArtwork)
                .shadow(color: .black.opacity(isHovering ? 0.18 : 0.08), radius: isHovering ? 10 : 5, y: 4)

                Text(item.title)
                    .font(.system(size: 16))
                    .foregroundStyle(
                        playback.isPlayingPlaylist(item.uri) ? SpottyPalette.mediaGreen : SpottyPalette.textPrimary
                    )
                    .lineLimit(titleLineLimit)

                Text(item.subtitle.isEmpty ? item.kind.rawValue : item.subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(SpottyPalette.textSecondary)
                    .lineLimit(2)
                    .frame(minHeight: 30, alignment: .topLeading)
            }
            .frame(width: CatalogLayout.cardArtwork, alignment: .leading)
            .padding(CatalogLayout.cardPadding)
            .contentShape(RoundedRectangle(cornerRadius: CatalogLayout.cardCornerRadius, style: .continuous))
            .background(
                SpottyPalette.mediaCardSurface(isHovering: isHovering),
                in: RoundedRectangle(cornerRadius: CatalogLayout.cardCornerRadius, style: .continuous)
            )
        }
        .pointingHandCursor()
        .help(item.kind == .track ? "Play \(item.title)" : "Open \(item.title)")
        .accessibilityLabel("\(item.title), \(item.subtitle.isEmpty ? item.kind.rawValue : item.subtitle)")
        .accessibilityHint(item.kind == .track ? "Starts playback" : "Opens details")
        // The card is itself a Button, so the play control is layered outside its label rather
        // than nested inside it; the insets place it 8pt inside the artwork's bottom-trailing corner.
        .overlay(alignment: .topTrailing) {
            CatalogCardPlayButton(item: item, playback: playback, isHovering: isHovering)
                .padding(.top, CatalogLayout.cardPadding + CatalogLayout.cardArtwork - 48 - 8)
                .padding(.trailing, CatalogLayout.cardPadding + 8)
        }
        .hoverSurface(isHovering: $isHovering)
    }
}
