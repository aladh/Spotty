import SpottyDomain
import SwiftUI

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
        .catalogTask(id: title, playback: playback) {
            guard playback.isConnected else { return }
            await reload()
        }
    }
}

struct TrackCollectionView: View {
    let title: String
    let subtitle: String
    let tracks: CatalogTrackCollection
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
                    playback: playback,
                    playlistActions: playlistActions
                )
            }
        }
        .navigationTitle(title)
    }
}
