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
    @State private var searchText = ""
    @State private var showsSearch = false
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
            guard playback.isConnected else { return }
            await store.load(item)
        }
        .onChange(of: searchFocused) {
            if !searchFocused && searchText.isEmpty { showsSearch = false }
        }
        .navigationTitle(item.title)
        .onChange(of: item.uri) {
            searchText = ""
            showsSearch = false
        }
    }

    private var expandedHeader: some View {
        VStack(spacing: 0) {
            MediaDetailHeader(
                item: item,
                description: store.description,
                detail: playlistMetadataText ?? "",
                style: .playlist
            )

            HStack(spacing: 24) {
                Button {
                    playback.playPlaylist(item)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.black)
                        .offset(x: 2)
                        .frame(width: 56, height: 56)
                        .background(SpottyPalette.mediaGreen, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!playback.canStartPlayback)
                .pointingHandCursor(enabled: playback.canStartPlayback)
                .accessibilityLabel("Play playlist")
                .help("Play playlist")

                Button {
                    playback.toggleShuffle()
                } label: {
                    Image(systemName: "shuffle")
                        .font(.system(size: 24))
                        .foregroundStyle(playback.isShuffleEnabled ? SpottyPalette.mediaGreen : .secondary)
                        .frame(width: 32, height: 40)
                        .overlay(alignment: .bottom) {
                            if playback.isShuffleEnabled {
                                Circle().fill(SpottyPalette.mediaGreen).frame(width: 4, height: 4)
                            }
                        }
                }
                .buttonStyle(.plain)
                .disabled(!playback.canStartPlayback)
                .pointingHandCursor(enabled: playback.canStartPlayback)
                .accessibilityLabel(playback.isShuffleEnabled ? "Disable shuffle" : "Enable shuffle")
                .help("Fewer repeats shuffle")

                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    Button {
                        showsSearch = true
                        searchFocused = true
                    } label: {
                        Image(systemName: "magnifyingglass").font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Search in playlist")
                    .help("Search in playlist")
                    if showsSearch {
                        TextField("Search in playlist", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .focused($searchFocused)
                            .frame(minWidth: 0, maxWidth: .infinity)
                            .onExitCommand {
                                if searchText.isEmpty {
                                    showsSearch = false
                                    searchFocused = false
                                } else {
                                    searchText = ""
                                }
                            }
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
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
                .frame(width: showsSearch ? 190 : 32, height: 32)
                .background(
                    showsSearch ? SpottyPalette.quickAccessSurface : .clear, in: RoundedRectangle(cornerRadius: 4))
            }
            .padding(.horizontal, CatalogLayout.contentPadding)
            .frame(height: 96)
            .background(SpottyPalette.catalogCanvas)

        }
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
            Text(item.title)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(SpottyPalette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
        .background(Color(white: 0.157))
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
        } else if store.isLoading && store.tracks.isEmpty {
            LoadingState(label: "Loading \(item.title)")
        } else if let error = store.error, store.tracks.isEmpty {
            EmptyState(
                icon: "exclamationmark.triangle",
                title: "Couldn't load this playlist",
                message: error,
                actionTitle: "Try Again",
                actionSystemImage: "arrow.clockwise"
            ) {
                Task { await store.load(item) }
            }
        } else if store.tracks.isEmpty {
            EmptyState(
                icon: "music.note.list",
                title: "This playlist is empty",
                message: "Spotify returned no playable tracks."
            )
        } else {
            VStack(spacing: 0) {
                if store.error != nil {
                    staleRefreshWarning
                    CatalogTableDivider()
                }
                TrackTable(
                    tracks: store.trackCollection,
                    metadata: metadata,
                    playback: playback,
                    variant: .playlist,
                    searchQuery: searchText,
                    playlistActions: playlistActions,
                    onSelect: onSelect,
                    playlistHeader: AnyView(expandedHeader),
                    compactPlaylistHeader: AnyView(compactHeader)
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
        store.loadedURI == item.uri
            && !store.isLoading
            && store.error == nil
    }

    private var matchingTracks: [CatalogTrack] {
        store.tracks.filter(PlaylistSearch(searchText).matches)
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
