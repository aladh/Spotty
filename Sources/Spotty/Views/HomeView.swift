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
                if store.isLoading(.home) && store.homeSections.isEmpty {
                    LoadingState(label: "Loading your Spotify home")
                } else if !playback.isConnected {
                    EmptyState(
                        icon: "music.note.house",
                        title: "Your music will appear here",
                        message: playback.statusText,
                        actionTitle: playback.connectionActionTitle,
                        actionSystemImage: "link"
                    ) {
                        playback.connect()
                    }
                } else if store.homeSections.isEmpty {
                    if let error = store.error(for: .home) {
                        EmptyState(
                            icon: "exclamationmark.triangle",
                            title: "Couldn't load Spotify Home",
                            message: error,
                            actionTitle: "Try Again",
                            actionSystemImage: "arrow.clockwise"
                        ) {
                            Task { await store.loadHome(force: true) }
                        }
                    } else {
                        EmptyState(
                            icon: "rectangle.stack",
                            title: "Spotify Home is empty",
                            message: "Spotify didn't return any recommendations."
                        )
                    }
                } else {
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
                    .padding(.bottom, -6)

                    ForEach(Array(store.homeSections.enumerated()), id: \.element.id) { index, section in
                        switch homeSectionPresentation(at: index) {
                        case .quickAccess:
                            QuickAccessShelf(section: section, onSelect: onSelect)
                        case .shelf:
                            MediaShelf(section: section, onSelect: onSelect)
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
    let onSelect: (CatalogItem) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 220, maximum: 340), spacing: 10)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.title)
                .font(.system(size: 24, weight: .bold))

            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(section.items.prefix(8)) { item in
                    QuickAccessCard(item: item) { onSelect(item) }
                }
            }
        }
    }
}

private struct QuickAccessCard: View {
    let item: CatalogItem
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                RemoteArtwork(
                    url: item.artworkURL,
                    kind: item.kind,
                    cornerRadius: item.kind == .artist ? 28 : 4,
                    pointSize: 56
                )
                .frame(width: 56, height: 56)

                Text(item.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(SpottyPalette.textPrimary)
                    .lineLimit(2)

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(SpottyPalette.textSecondary)
                    .opacity(isHovering ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.trailing, 14)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(
                SpottyPalette.quickAccessSurface(isHovering: isHovering),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverSurface(isHovering: $isHovering)
        .help(item.kind == .track ? "Play \(item.title)" : "Open \(item.title)")
        .accessibilityLabel(item.title)
        .accessibilityHint(item.kind == .track ? "Starts playback" : "Opens details")
    }
}

struct MediaShelf: View {
    let section: CatalogSection
    let onSelect: (CatalogItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(section.title)
                .font(.system(size: 24, weight: .bold))

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(section.items) { item in
                        MediaCard(item: item) { onSelect(item) }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

struct MediaCard: View {
    let item: CatalogItem
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                RemoteArtwork(
                    url: item.artworkURL,
                    kind: item.kind,
                    cornerRadius: item.kind == .artist ? CatalogLayout.cardArtwork / 2 : 10,
                    pointSize: CatalogLayout.cardArtwork
                )
                .frame(width: CatalogLayout.cardArtwork, height: CatalogLayout.cardArtwork)
                .shadow(color: .black.opacity(isHovering ? 0.18 : 0.08), radius: isHovering ? 10 : 5, y: 4)

                Text(item.title)
                    .font(.system(size: 16))
                    .foregroundStyle(SpottyPalette.textPrimary)
                    .lineLimit(1)

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
        .buttonStyle(.plain)
        .hoverSurface(isHovering: $isHovering)
        .help(item.kind == .track ? "Play \(item.title)" : "Open \(item.title)")
        .accessibilityLabel("\(item.title), \(item.subtitle.isEmpty ? item.kind.rawValue : item.subtitle)")
        .accessibilityHint(item.kind == .track ? "Starts playback" : "Opens details")
    }
}
