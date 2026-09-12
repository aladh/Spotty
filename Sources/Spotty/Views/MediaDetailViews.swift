import SpottyDomain
import SwiftUI

private struct MediaDetailLoadIdentity: Equatable {
    let uri: String
    let accountEpoch: UInt64
    let isConnected: Bool
}

struct AlbumDetailView: View {
    let item: CatalogItem
    let store: AlbumDetailStore
    let metadata: CatalogMetadataRepository
    let playback: CatalogPlaybackAccess
    var playlistActions: TrackPlaylistActions? = nil
    let interactionState: CatalogRouteInteractionState

    private var displayedItem: CatalogItem {
        store.item?.uri == item.uri ? (store.item ?? item) : item
    }

    var body: some View {
        VStack(spacing: 0) {
            DetailHeroBackground(artworkURL: displayedItem.artworkURL) {
                VStack(spacing: 0) {
                    MediaDetailHeader(item: displayedItem, detail: store.releaseDate)
                    DetailActionRow(
                        canPlay: playback.canStartPlayback,
                        playAccessibilityLabel: "Play",
                        playAccessibilityHint: "Starts this album"
                    ) {
                        playback.playURI(item.uri)
                    }
                }
            }
            CatalogTableDivider()
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
                    metadata: metadata,
                    playback: playback,
                    playlistActions: playlistActions,
                    interactionState: interactionState
                )
            }
        }
        .navigationTitle(displayedItem.title)
        .task(
            id: MediaDetailLoadIdentity(
                uri: item.uri,
                accountEpoch: playback.accountEpoch,
                isConnected: playback.isConnected
            )
        ) {
            await store.load(item)
        }
    }
}

struct ArtistDetailView: View {
    let item: CatalogItem
    let store: ArtistDetailStore
    let playback: CatalogPlaybackAccess
    let onSelect: (CatalogItem) -> Void
    @Bindable var interactionState: CatalogRouteInteractionState

    private var displayedItem: CatalogItem {
        store.item?.uri == item.uri ? (store.item ?? item) : item
    }

    var body: some View {
        VStack(spacing: 0) {
            DetailHeroBackground(artworkURL: displayedItem.artworkURL) {
                VStack(spacing: 0) {
                    MediaDetailHeader(item: displayedItem)
                    DetailActionRow(
                        canPlay: playback.canStartPlayback,
                        playAccessibilityLabel: "Play",
                        playAccessibilityHint: "Starts playback for this artist"
                    ) {
                        playback.playURI(item.uri)
                    }
                }
            }
            CatalogTableDivider()
            if store.isShowingCachedContent {
                CachedCatalogNotice(isRefreshing: store.isLoading)
            }
            CatalogContentState(
                isLoading: store.isLoading, isEmpty: store.releases.isEmpty, error: store.error,
                loadingLabel: "Loading artist", errorTitle: "Couldn't load artist",
                retry: { await store.load(item) }
            ) {
                EmptyState(
                    icon: "person.wave.2", title: "No releases",
                    message: "Spotify returned no releases for this artist.")
            } content: {
                ScrollView {
                    LazyVGrid(
                        columns: MediaGridLayout.columns,
                        alignment: .leading,
                        spacing: 18
                    ) {
                        ForEach(store.releases) { release in
                            MediaCard(item: release, playback: playback) { onSelect(release) }
                        }
                    }
                    .scrollTargetLayout()
                    .padding(CatalogLayout.contentPadding)
                }
                .scrollPosition(id: $interactionState.visibleItemID, anchor: .top)
                .id(item.uri)
            }
        }
        .navigationTitle(displayedItem.title)
        .task(
            id: MediaDetailLoadIdentity(
                uri: item.uri,
                accountEpoch: playback.accountEpoch,
                isConnected: playback.isConnected
            )
        ) {
            await store.load(item)
        }
    }
}
