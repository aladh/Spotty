import SpottyDomain
import OSLog
import SwiftUI

struct RootView: View {
    let player: PlaybackStore
    let catalog: CatalogStore
    let feedback: TransientFeedbackPresenter

    @State private var navigation: CatalogNavigation
    @SceneStorage("showsPlaybackInspector") private var showsSidePanel = false
    @SceneStorage("playbackInspectorPanel") private var playbackPanel = PlaybackPanel.queue

    init(
        player: PlaybackStore, catalog: CatalogStore, feedback: TransientFeedbackPresenter,
        navigation: CatalogNavigation? = nil
    ) {
        self.player = player
        self.catalog = catalog
        self.feedback = feedback
        _navigation = State(initialValue: navigation ?? CatalogNavigation())
    }

    var body: some View {
        @Bindable var navigation = navigation
        VStack(spacing: 0) {
            HSplitView {
                SidebarView(
                    selection: selectionBinding, library: catalog.homeLibrary.playlistLibrary,
                    playback: catalogPlayback,
                    isLoading: catalog.homeLibrary.isLoading(.playlists)
                )
                .frame(minWidth: 180, idealWidth: 208, maxWidth: 260)
                .frame(maxHeight: .infinity)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background { SpottyPalette.catalogCanvas.ignoresSafeArea() }
            }
            .inspector(isPresented: $showsSidePanel) {
                SidePanelView(
                    metadata: catalog.metadata,
                    player: player,
                    panel: playbackPanel,
                    onSelect: select,
                    onClose: { showsSidePanel = false }
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .background(.black)
                .inspectorColumnWidth(min: 260, ideal: 280, max: 360)
            }
            .overlay(alignment: .bottom) {
                TransientFeedbackBanner(feedback: feedback)
            }

            NowPlayingBar(player: player, showsSidePanel: $showsSidePanel, playbackPanel: $playbackPanel)
        }
        .foregroundStyle(SpottyPalette.textPrimary)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button("Go back", systemImage: "chevron.left", action: navigation.goBack)
                    .disabled(navigation.backHistory.isEmpty)
                    .keyboardShortcut("[", modifiers: .command)
                Button("Go forward", systemImage: "chevron.right", action: navigation.goForward)
                    .disabled(navigation.forwardHistory.isEmpty)
                    .keyboardShortcut("]", modifiers: .command)
            }
            ToolbarItem(placement: .principal) {
                NavigationBar(
                    searchText: $navigation.searchText,
                    isHome: selection == .destination(.home),
                    goHome: { navigation.updateSelection(.destination(.home)) },
                    showSearch: { navigation.updateSelection(.destination(.search)) }
                )
            }
        }
        .toolbarBackground(.black, for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .onChange(of: player.accountEpoch) {
            navigation.reset()
        }
        .onChange(of: navigation.rawValue) {
            SpottyLog.ui.info("Navigation state updated: \(mediaSelection.diagnosticLabel, privacy: .public)")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case let .destination(destination):
            destinationView(destination)
        case let .playlist(uri):
            if let item = playlistItem(for: uri) {
                PlaylistDetailView(
                    item: item,
                    store: catalog.playlistStore,
                    metadata: catalog.metadata,
                    playback: catalogPlayback,
                    playlistActions: playlistActions(removingFrom: item),
                    onSelect: select
                )
            } else if catalog.homeLibrary.isLoading(.playlists) {
                LoadingState(label: "Loading playlist")
            } else if let error = catalog.homeLibrary.error(for: .playlists) {
                EmptyState(
                    icon: "exclamationmark.triangle",
                    title: "Couldn't restore this playlist",
                    message: error,
                    actionTitle: "Try Again",
                    actionSystemImage: "arrow.clockwise"
                ) {
                    Task { await catalog.homeLibrary.loadPlaylists() }
                }
                .padding(30)
            } else {
                unavailableMedia("Playlist", destination: .home)
            }
        case let .album(uri):
            if let item = selectedItem(uri: uri, kind: .album) {
                AlbumDetailView(
                    item: item,
                    store: catalog.albumStore,
                    metadata: catalog.metadata,
                    playback: catalogPlayback,
                    playlistActions: playlistActions()
                )
            } else {
                unavailableMedia("Album", destination: .albums)
            }
        case let .artist(uri):
            if let item = selectedItem(uri: uri, kind: .artist) {
                ArtistDetailView(
                    item: item,
                    store: catalog.artistStore,
                    playback: catalogPlayback,
                    onSelect: select
                )
            } else {
                unavailableMedia("Artist", destination: .artists)
            }
        }
    }

    @ViewBuilder
    private func destinationView(_ destination: SidebarDestination) -> some View {
        switch destination {
        case .home, .playlists:
            HomeView(store: catalog.homeLibrary, playback: catalogPlayback, onSelect: select)
        case .search:
            SearchView(
                store: catalog.searchStore,
                metadata: catalog.metadata,
                playback: catalogPlayback,
                searchText: Bindable(navigation).searchText,
                onSelect: select,
                playlistActions: playlistActions()
            )
        case .liked:
            TrackCollectionView(
                title: "Liked Songs",
                subtitle: catalogPlayback.isConnected
                    ? "Saved to your Spotify library"
                    : "Connect Spotify to load your saved tracks",
                tracks: catalog.homeLibrary.likedTrackCollection,
                metadata: catalog.metadata,
                playback: catalogPlayback,
                reloadError: catalog.homeLibrary.error(for: .likedTracks),
                reload: { await catalog.homeLibrary.loadLikedTracks(force: true) },
                isLoading: catalog.homeLibrary.isLoading(.likedTracks),
                emptyIcon: "heart",
                emptyTitle: "No liked songs",
                emptyMessage: "Songs you save on Spotify will appear here.",
                playlistActions: playlistActions()
            )
            .task(id: catalogPlayback.accountEpoch) {
                guard catalogPlayback.isConnected else { return }
                await catalog.homeLibrary.loadLikedTracks()
            }
        case .albums:
            LibraryView(
                title: "Albums",
                items: catalog.homeLibrary.albums,
                isLoading: catalog.homeLibrary.isLoading(.albums),
                error: catalog.homeLibrary.error(for: .albums),
                reload: { await catalog.homeLibrary.loadAlbums() },
                playback: catalogPlayback,
                onSelect: select
            )
        case .artists:
            LibraryView(
                title: "Artists",
                items: catalog.homeLibrary.artists,
                isLoading: catalog.homeLibrary.isLoading(.artists),
                error: catalog.homeLibrary.error(for: .artists),
                reload: { await catalog.homeLibrary.loadArtists() },
                playback: catalogPlayback,
                onSelect: select
            )
        }
    }

    private func select(_ item: CatalogItem) {
        switch navigation.select(item) {
        case .navigate:
            break
        case let .play(uri):
            catalogPlayback.playURI(uri)
        }
    }

    private func selectedItem(uri: String, kind: CatalogItem.Kind) -> CatalogItem? {
        mediaSelection.item(
            uri: uri,
            kind: kind,
            metadataItem: catalog.metadata.knownItem(for: uri)
        )
    }

    private func unavailableMedia(
        _ kind: String,
        destination: SidebarDestination
    ) -> some View {
        EmptyState(
            icon: "questionmark.square.dashed",
            title: "\(kind) unavailable",
            message: "This item is no longer available in the loaded catalog.",
            actionTitle: "Show \(destination.rawValue)",
            actionSystemImage: "arrow.left"
        ) {
            navigation.updateSelection(.destination(destination))
        }
        .padding(30)
    }

    private func playlistItem(for uri: String) -> CatalogItem? {
        mediaSelection.item(
            uri: uri,
            kind: .playlist,
            playlists: catalog.homeLibrary.playlists,
            metadataItem: catalog.metadata.knownItem(for: uri)
        )
    }

    private var selection: SidebarSelection {
        mediaSelection.selection
    }

    private var mediaSelection: MediaSelectionModel {
        navigation.model
    }

    private var catalogPlayback: CatalogPlaybackAccess {
        CatalogPlaybackAccess(player: player)
    }

    private func playlistActions(removingFrom openPlaylist: CatalogItem? = nil) -> TrackPlaylistActions {
        TrackPlaylistActions(
            editablePlaylists: catalog.playlistMutations.editableLibraryPlaylists,
            canRemoveOccurrences: openPlaylist.map { catalog.playlistMutations.isOpenPlaylistEditable($0) } ?? false,
            addToPlaylist: { playlist, tracks in
                catalog.playlistMutations.addTracks(tracks, to: playlist)
            },
            removeOccurrences: { ids in
                guard let openPlaylist else { return }
                catalog.playlistMutations.removeOccurrences(selectedIDs: Set(ids), from: openPlaylist)
            }
        )
    }

    private var selectionBinding: Binding<SidebarSelection?> {
        Binding(
            get: { selection },
            set: { selection in
                navigation.updateSelection(selection)
            }
        )
    }

}
