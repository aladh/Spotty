import SpottyDomain
import SwiftUI

private struct SearchLoadIdentity: Equatable {
    let query: String
    let accountEpoch: UInt64
    let isConnected: Bool
}

struct SearchView: View {
    let store: SearchStore
    let metadata: CatalogMetadataRepository
    let playback: CatalogPlaybackAccess
    @Binding var searchText: String
    let onSelect: (CatalogItem) -> Void
    let playlistActions: TrackPlaylistActions

    var body: some View {
        Group {
            if !playback.isConnected {
                EmptyState(
                    icon: "person.crop.circle.badge.plus",
                    title: "Connect Spotify",
                    message: "Connect your Spotify Premium account to search its track catalog.",
                    actionTitle: playback.connectionActionTitle,
                    actionSystemImage: "link"
                ) {
                    playback.connect()
                }
                .padding(CatalogLayout.contentPadding)
            } else if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                EmptyState(
                    icon: "magnifyingglass",
                    title: "Search Spotify",
                    message: "Find tracks, artists, albums, and playlists."
                )
                .padding(CatalogLayout.contentPadding)
            } else {
                CatalogContentState(
                    isLoading: store.isSearching, isEmpty: store.isEmpty, error: store.error,
                    loadingLabel: "Searching Spotify", errorTitle: "Couldn't search Spotify",
                    errorIcon: "exclamationmark.magnifyingglass", placeholderPadding: CatalogLayout.contentPadding,
                    retry: { await store.search(searchText) }
                ) {
                    EmptyState(
                        icon: "magnifyingglass", title: "No results for “\(searchText)”",
                        message: "Try another track, artist, or album.")
                } content: {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 24) {
                            if !store.failedSections.isEmpty {
                                partialFailureBanner
                            }
                            if !store.artists.isEmpty {
                                MediaShelf(
                                    section: CatalogSection(
                                        id: "search-artists", title: "Artists", items: store.artists),
                                    playback: playback,
                                    onSelect: onSelect
                                )
                            }
                            if !store.albums.isEmpty {
                                MediaShelf(
                                    section: CatalogSection(id: "search-albums", title: "Albums", items: store.albums),
                                    playback: playback,
                                    onSelect: onSelect
                                )
                            }
                            if !store.playlists.isEmpty {
                                MediaShelf(
                                    section: CatalogSection(
                                        id: "search-playlists", title: "Playlists", items: store.playlists),
                                    playback: playback,
                                    onSelect: onSelect
                                )
                            }
                            if !store.tracks.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Tracks").font(.system(size: 24, weight: .bold))
                                    TrackTable(
                                        tracks: store.trackCollection,
                                        metadata: metadata,
                                        playback: playback,
                                        playlistActions: playlistActions
                                    )
                                    .frame(minHeight: 280)
                                }
                            }
                        }
                        .padding(CatalogLayout.contentPadding)
                    }
                }
            }
        }
        .navigationTitle("Search")
        .task(
            id: SearchLoadIdentity(
                query: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
                accountEpoch: playback.accountEpoch,
                isConnected: playback.isConnected
            )
        ) {
            guard playback.isConnected else { return }
            await store.scheduleSearch(searchText)
        }
    }

    private var partialFailureBanner: some View {
        HStack(spacing: 10) {
            Label(
                "Some results couldn't load: \(failedSectionNames)",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(SpottyPalette.textSecondary)

            Spacer()

            Button("Try Again", systemImage: "arrow.clockwise") {
                Task { await store.search(searchText) }
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var failedSectionNames: String {
        store.failedSections.map { $0.rawValue.capitalized }.joined(separator: ", ")
    }
}

struct LibraryView: View {
    let title: String
    let items: [CatalogItem]
    let isLoading: Bool
    let error: String?
    let reload: () async -> Void
    let playback: CatalogPlaybackAccess
    let onSelect: (CatalogItem) -> Void

    var body: some View {
        ScrollView {
            CatalogContentState(
                isLoading: isLoading, isEmpty: items.isEmpty, error: error,
                loadingLabel: "Loading \(title.lowercased())", errorTitle: "Couldn't load \(title.lowercased())",
                placeholderPadding: CatalogLayout.contentPadding, connection: playback, retry: reload
            ) {
                EmptyState(
                    icon: "tray", title: "No \(title.lowercased()) found",
                    message: "This part of your Spotify library is empty.")
            } content: {
                VStack(alignment: .leading, spacing: 20) {
                    Text(title)
                        .font(.system(size: 32, weight: .bold))

                    LazyVGrid(
                        columns: MediaGridLayout.columns,
                        alignment: .leading,
                        spacing: CatalogLayout.gridSpacing
                    ) {
                        ForEach(items) { item in
                            MediaCard(item: item, playback: playback) { onSelect(item) }
                        }
                    }
                }
                .padding(CatalogLayout.contentPadding)
            }
        }
        .navigationTitle(title)
        .task(id: playback.accountEpoch) {
            guard playback.isConnected else { return }
            await reload()
        }
    }
}

struct TrackCollectionView: View {
    let title: String
    let subtitle: String
    let tracks: CatalogTrackCollection
    let metadata: CatalogMetadataRepository
    let playback: CatalogPlaybackAccess
    var reloadError: String? = nil
    var reload: () async -> Void = {}
    var isLoading = false
    var emptyIcon = "music.note"
    var emptyTitle: String? = nil
    var emptyMessage: String? = nil
    var playlistActions: TrackPlaylistActions? = nil

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 32, weight: .bold))
                    .lineLimit(2)
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(SpottyPalette.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(CatalogLayout.contentPadding)

            CatalogTableDivider()

            CatalogContentState(
                isLoading: isLoading, isEmpty: tracks.tracks.isEmpty, error: reloadError,
                loadingLabel: "Loading \(title.lowercased())", errorTitle: "Couldn't load tracks",
                connection: playback, connectionMessage: "Your Spotify tracks will appear after you connect.",
                retry: reload
            ) {
                EmptyState(icon: emptyIcon, title: emptyTitle ?? "No tracks to show", message: emptyMessage ?? subtitle)
            } content: {
                TrackTable(
                    tracks: tracks,
                    metadata: metadata,
                    playback: playback,
                    playlistActions: playlistActions
                )
            }
        }
        .navigationTitle(title)
    }
}
