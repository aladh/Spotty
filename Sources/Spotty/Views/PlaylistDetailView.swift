import SpottyDomain
import SwiftUI

struct PlaylistDetailView: View {
    let item: CatalogItem
    let store: PlaylistStore
    let playback: CatalogPlaybackAccess
    let playlistActions: TrackPlaylistActions
    let onSelect: (CatalogItem) -> Void
    @Bindable var interactionState: CatalogRouteInteractionState
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            if store.tracks.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        expandedHeader
                        playlistContent
                    }
                }
                .id(item.uri)
            } else {
                playlistContent
            }
        }
        .catalogTask(id: item.uri, playback: playback) {
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
                    action: playback.action(for: displayedItem, behavior: .activateSelection),
                    shuffle: DetailActionRowShuffle(
                        isEnabled: playback.isShuffleEnabled, canToggle: playback.canStartPlayback,
                        toggle: { playback.toggleShuffle() }
                    )
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
        CompactMediaDetailHeader(
            title: displayedItem.title,
            action: playback.action(for: displayedItem, behavior: .activateSelection)
        )
    }

    private var playlistContent: some View {
        VStack(spacing: 0) {
            if store.error != nil && !store.tracks.isEmpty {
                staleRefreshWarning
                CatalogTableDivider()
            } else if store.isShowingCachedContent {
                // Keep the freshness notice outside the loading/empty/error ladder so an
                // empty saved result remains labeled when its background refresh fails.
                CachedCatalogNotice(isRefreshing: store.isLoading)
            }
            CatalogContentState(
                isLoading: store.isLoadingInitialContent, isEmpty: store.tracks.isEmpty, error: store.error,
                loadingLabel: "Loading \(item.title)", errorTitle: "Couldn't load this playlist",
                connection: playback, connectionIcon: "wifi.exclamationmark",
                connectionTitle: "Reconnect to load this playlist",
                retry: { await store.load(item) }
            ) {
                EmptyState(
                    icon: "music.note.list", title: "This playlist is empty",
                    message: "Spotify returned no playable tracks.")
            } content: {
                TrackTable(
                    tracks: store.trackCollection,
                    playback: playback,
                    variant: .playlist,
                    searchQuery: interactionState.searchText,
                    playlistActions: playlistActions,
                    onSelect: onSelect,
                    detailHeader: AnyView(expandedHeader),
                    compactDetailHeader: AnyView(compactHeader),
                    interactionState: interactionState
                )
                .id(item.uri)
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
        store.loadedURI == item.uri && store.hasLoadedContent
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
