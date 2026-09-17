import SpottyDomain
import SwiftUI

struct AlbumDetailView: View {
    let item: CatalogItem
    let store: AlbumDetailStore
    let playback: CatalogPlaybackAccess
    var playlistActions: TrackPlaylistActions? = nil
    let onSelect: (CatalogItem) -> Void
    let interactionState: CatalogRouteInteractionState

    private var displayedItem: CatalogItem {
        store.item?.uri == item.uri ? (store.item ?? item) : item
    }

    var body: some View {
        Group {
            if store.tracks.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        expandedHeader
                        albumContent
                    }
                }
                .id(item.uri)
            } else {
                albumContent
            }
        }
        .navigationTitle(displayedItem.title)
        .catalogTask(id: item.uri, playback: playback) {
            await store.load(item)
        }
    }

    private var albumContent: some View {
        VStack(spacing: 0) {
            if store.isShowingCachedContent {
                CachedCatalogNotice(isRefreshing: store.isLoading)
            }
            CatalogContentState(
                isLoading: store.isLoading, isEmpty: store.tracks.isEmpty, error: store.error,
                loadingLabel: "Loading album", errorTitle: "Couldn't load album",
                retry: { await store.load(item) }
            ) {
                EmptyState(icon: "square.stack", title: "No tracks", message: "Spotify returned an empty album.")
            } content: {
                TrackTable(
                    tracks: store.trackCollection,
                    playback: playback,
                    variant: .album,
                    playlistActions: playlistActions,
                    onSelect: onSelect,
                    detailHeader: AnyView(expandedHeader),
                    compactDetailHeader: AnyView(compactHeader),
                    playCounts: store.playCounts,
                    interactionState: interactionState
                )
                .id(item.uri)
            }
        }
    }

    private var expandedHeader: some View {
        DetailHeroBackground(artworkURL: displayedItem.artworkURL) {
            VStack(spacing: 0) {
                MediaDetailHeader(
                    item: displayedItem, detail: metadataText, style: .album,
                    artists: store.artists, onSelect: onSelect)
                DetailActionRow(
                    canPlay: playback.canStartPlayback,
                    playAccessibilityLabel: "Play album",
                    playAccessibilityHint: "Starts this album"
                ) {
                    playback.playURI(item.uri)
                }
            }
        }
    }

    private var compactHeader: some View {
        CompactMediaDetailHeader(
            title: displayedItem.title,
            canPlay: playback.canStartPlayback,
            playAccessibilityLabel: "Play album"
        ) {
            playback.playURI(item.uri)
        }
    }

    private var metadataText: String {
        let year = String(store.releaseDate.prefix(4))
        guard !store.tracks.isEmpty else { return year }
        let count = store.tracks.count
        let duration = store.tracks.reduce(0.0) { $0 + $1.duration }.rounded(.down)
        return [year, "\(count) \(count == 1 ? "song" : "songs"), \(formatPlaylistDuration(duration))"]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
