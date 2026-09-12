import SpottyDomain
import SwiftUI

private struct PlaylistLoadIdentity: Equatable {
    let uri: String
    let accountEpoch: UInt64
    let isConnected: Bool
}

struct PlaylistDetailView: View {
    let item: CatalogItem
    let store: PlaylistStore
    let metadata: CatalogMetadataRepository
    let playback: CatalogPlaybackAccess
    let playlistActions: TrackPlaylistActions
    let onSelect: (CatalogItem) -> Void
    @Bindable var interactionState: CatalogRouteInteractionState
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if store.tracks.isEmpty { expandedHeader }

            playlistContent
        }
        .task(
            id: PlaylistLoadIdentity(
                uri: item.uri,
                accountEpoch: playback.accountEpoch,
                isConnected: playback.isConnected
            )
        ) {
            await store.load(item)
        }
        .onChange(of: searchFocused) {
            if !searchFocused && interactionState.searchText.isEmpty { interactionState.showsSearch = false }
        }
        .navigationTitle(displayedItem.title)
    }

    private var displayedItem: CatalogItem {
        store.item?.uri == item.uri ? (store.item ?? item) : item
    }

    private var expandedHeader: some View {
        DetailHeroBackground(artworkURL: displayedItem.artworkURL) {
            VStack(spacing: 0) {
                MediaDetailHeader(
                    item: displayedItem,
                    description: store.description,
                    detail: playlistMetadataText ?? "",
                    style: .playlist
                )

                DetailActionRow(
                    canPlay: playback.canStartPlayback,
                    playAccessibilityLabel: "Play playlist",
                    shuffle: DetailActionRowShuffle(
                        isEnabled: playback.isShuffleEnabled,
                        toggle: { playback.toggleShuffle() }
                    ),
                    play: { playback.playPlaylist(item) }
                ) {
                    searchField
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Button {
                interactionState.showsSearch = true
                searchFocused = true
            } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search in playlist")
            .help("Search in playlist")
            if interactionState.showsSearch {
                TextField("Search in playlist", text: $interactionState.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .onExitCommand {
                        if interactionState.searchText.isEmpty {
                            interactionState.showsSearch = false
                            searchFocused = false
                        } else {
                            interactionState.searchText = ""
                        }
                    }
                if !interactionState.searchText.isEmpty {
                    Button {
                        interactionState.searchText = ""
                        searchFocused = true
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search field")
                }
            }
        }
        .padding(8)
        .frame(width: interactionState.showsSearch ? 190 : 32, height: 32)
        .background(
            interactionState.showsSearch ? SpottyPalette.quickAccessSurface : .clear,
            in: RoundedRectangle(cornerRadius: 4))
    }

    private var compactHeader: some View {
        HStack(spacing: 8) {
            Button {
                playback.playPlaylist(item)
            } label: {
                TransportSymbol(kind: .play)
                    .foregroundStyle(.black)
                    .frame(width: 20, height: 20)
                    .frame(width: 48, height: 48)
                    .background(SpottyPalette.mediaGreen, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!playback.canStartPlayback)
            .pointingHandCursor(enabled: playback.canStartPlayback)
            .accessibilityLabel("Play playlist")
            Text(displayedItem.title)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(SpottyPalette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
        .background(SpottyPalette.selectedControl)
    }

    @ViewBuilder
    private var playlistContent: some View {
        if !playback.isConnected && store.tracks.isEmpty {
            VStack(spacing: 14) {
                ContentUnavailableView(
                    "Reconnect to load this playlist",
                    systemImage: "wifi.exclamationmark",
                    description: Text(playback.statusText)
                )
                Button(playback.connectionActionTitle) { playback.connect() }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, minHeight: 240)
        } else {
            CatalogContentState(
                isLoading: store.isLoading, isEmpty: store.tracks.isEmpty, error: store.error,
                loadingLabel: "Loading \(item.title)", errorTitle: "Couldn't load this playlist",
                retry: { await store.load(item) }
            ) {
                EmptyState(
                    icon: "music.note.list", title: "This playlist is empty",
                    message: "Spotify returned no playable tracks.")
            } content: {
                VStack(spacing: 0) {
                    if store.error != nil {
                        staleRefreshWarning
                        CatalogTableDivider()
                    } else if store.isShowingCachedContent {
                        CachedCatalogNotice(isRefreshing: store.isLoading)
                    }
                    TrackTable(
                        tracks: store.trackCollection,
                        metadata: metadata,
                        playback: playback,
                        variant: .playlist,
                        searchQuery: interactionState.searchText,
                        playlistActions: playlistActions,
                        onSelect: onSelect,
                        playlistHeader: AnyView(expandedHeader),
                        compactPlaylistHeader: AnyView(compactHeader),
                        interactionState: interactionState
                    )
                    .id(item.uri)
                }
            }
        }
    }

    private var staleRefreshWarning: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(SpottyPalette.textSecondary)
                .accessibilityHidden(true)
            Text("Couldn't refresh this playlist. The songs shown may be out of date.")
                .font(.subheadline)
                .foregroundStyle(SpottyPalette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry") {
                Task { await store.load(item, force: true) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(store.isLoading)
            .accessibilityHint("Reload the playlist without repeating the last change.")
        }
        .padding(.horizontal, CatalogLayout.contentPadding)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }

    private var showsPlaylistMetadata: Bool {
        store.loadedURI == item.uri
            && !store.isLoading
            && store.error == nil
    }

    private var matchingTracks: [CatalogTrack] {
        store.tracks.filter(PlaylistSearch(interactionState.searchText).matches)
    }

    private var songCountText: String {
        let count = matchingTracks.count
        return "\(count) \(count == 1 ? "song" : "songs")"
    }

    private var playlistMetadataText: String? {
        guard showsPlaylistMetadata else { return nil }
        let duration = matchingTracks.reduce(0.0) { $0 + Double(roundedCatalogDurationSeconds($1.duration)) }
        return [songCountText, formatPlaylistDuration(duration)].joined(separator: " · ")
    }

}
