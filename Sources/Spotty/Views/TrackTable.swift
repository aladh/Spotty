import SpottyDomain
import SwiftUI

enum TrackTableVariant: Equatable {
    case catalog
    case playlist

    var initialSortOrder: [KeyPathComparator<TrackTableRow>] {
        switch self {
        case .catalog:
            []
        case .playlist:
            [KeyPathComparator(\TrackTableRow.dateAddedSortValue, order: .reverse)]
        }
    }
}

/// A native macOS table shared by playlists, search results, and track libraries.
/// Single-click selects; command-click extends a simple multi-selection; double-click
/// or Return plays the primary row, matching desktop table behavior.
struct TrackTable: View {
    let tracks: CatalogTrackCollection
    let metadata: CatalogMetadataRepository
    let playback: CatalogPlaybackAccess
    let variant: TrackTableVariant
    let searchQuery: String
    var playlistActions: TrackPlaylistActions?
    let onSelect: ((CatalogItem) -> Void)?
    let playlistHeader: AnyView?
    let compactPlaylistHeader: AnyView?
    @State private var selection: Set<CatalogTrack.ID> = []
    @State private var sortOrder: [KeyPathComparator<TrackTableRow>] = []
    @State private var displayCache = TrackTableDisplayCache()
    @State private var visibleRows: [TrackTableRow] = []

    init(
        tracks: CatalogTrackCollection,
        metadata: CatalogMetadataRepository,
        playback: CatalogPlaybackAccess,
        variant: TrackTableVariant = .catalog,
        searchQuery: String = "",
        playlistActions: TrackPlaylistActions? = nil,
        onSelect: ((CatalogItem) -> Void)? = nil,
        playlistHeader: AnyView? = nil,
        compactPlaylistHeader: AnyView? = nil
    ) {
        self.tracks = tracks
        self.metadata = metadata
        self.playback = playback
        self.variant = variant
        self.searchQuery = searchQuery
        self.playlistActions = playlistActions
        self.onSelect = onSelect
        self.playlistHeader = playlistHeader
        self.compactPlaylistHeader = compactPlaylistHeader
        let initialSortOrder = variant.initialSortOrder
        _sortOrder = State(initialValue: initialSortOrder)
    }

    var body: some View {
        Group {
            if variant == .playlist {
                PlaylistTrackList(
                    rows: visibleRows, playback: playback, searchQuery: searchQuery,
                    selection: $selection, sortOrder: $sortOrder, onSelect: onSelect,
                    playlistHeader: playlistHeader, compactPlaylistHeader: compactPlaylistHeader
                )
            } else {
                Table(visibleRows, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Title", value: \.title) { row in
                        titleCell(row.track)
                    }
                    .width(min: 152, ideal: 224, max: 264)

                    TableColumn("Artist", value: \.artist) { row in
                        Text(row.track.artist).foregroundStyle(SpottyPalette.textSecondary).lineLimit(1)
                    }
                    .width(min: 96, ideal: 124, max: 160)

                    TableColumn("Album", value: \.album) { row in
                        Text(row.track.album).foregroundStyle(SpottyPalette.textSecondary).lineLimit(1)
                    }
                    .width(min: 96, ideal: 132, max: 170)

                    TableColumn("Popularity", value: \.popularitySortValue) { row in
                        Text(attributeText(metadata.trackAttributes[row.track.uri]?.popularity.map(String.init)))
                            .foregroundStyle(SpottyPalette.dataText)
                    }
                    .width(64)

                    TableColumn("BPM", value: \.bpmSortValue) { row in
                        let text = attributeText(metadata.trackAttributes[row.track.uri]?.bpm.map(String.init))
                        Text(text)
                            .monospacedDigit()
                            .foregroundStyle(SpottyPalette.dataText)
                            .accessibilityLabel("BPM")
                            .accessibilityValue(text)
                    }
                    .width(44)

                    TableColumn("Key", value: \.keySortValue) { row in
                        Text(attributeText(metadata.trackAttributes[row.track.uri]?.key))
                            .foregroundStyle(SpottyPalette.dataText)
                    }
                    .width(38)

                    TableColumn("Time", value: \.duration) { row in
                        Text(formatDuration(row.track.duration))
                            .monospacedDigit()
                            .foregroundStyle(SpottyPalette.dataText)
                    }
                    .width(44)
                }
            }
        }
        .contextMenu(forSelectionType: CatalogTrack.ID.self) { selectedIDs in
            let selectedTracks = PlaylistMutationSelection.orderedTracks(
                selectedIDs: selectedIDs,
                in: visibleRows.map(\.track)
            )
            if selectedTracks.count == 1, let track = selectedTracks.first {
                Button("Play", systemImage: "play.fill") {
                    play(track)
                }
                .disabled(!playback.canStartPlayback)
            }

            if !selectedTracks.isEmpty {
                Button("Add to Queue", systemImage: "text.line.first.and.arrowtriangle.forward") {
                    playback.addToQueue(QueueMutationSelection.addURIs(from: selectedTracks))
                }
                .disabled(!playback.canStartPlayback)
            }

            if !selectedTracks.isEmpty, let playlistActions {
                Menu("Add to Playlist") {
                    if playlistActions.editablePlaylists.isEmpty {
                        Button("No Editable Playlists") {}
                            .disabled(true)
                    } else {
                        ForEach(playlistActions.editablePlaylists) { playlist in
                            Button(playlist.title) {
                                playlistActions.addToPlaylist(playlist, selectedTracks)
                            }
                        }
                    }
                }
                .accessibilityLabel("Add to Playlist")

                if playlistActions.canRemoveOccurrences {
                    Divider()
                    Button("Remove from Playlist", role: .destructive) {
                        playlistActions.removeOccurrences(
                            PlaylistMutationSelection.occurrenceIDsForRemoval(from: selectedTracks)
                        )
                    }
                    .disabled(
                        PlaylistMutationSelection.occurrenceIDsForRemoval(from: selectedTracks).isEmpty
                    )
                }
            }
        } primaryAction: { selectedIDs in
            let selectedTracks = PlaylistMutationSelection.orderedTracks(
                selectedIDs: selectedIDs,
                in: visibleRows.map(\.track)
            )
            guard selectedTracks.count == 1, let track = selectedTracks.first else { return }
            play(track)
        }
        .onDeleteCommandIfAvailable(playlistActions?.canRemoveOccurrences == true) {
            removeSelectedOccurrences()
        }
        .accessibilityLabel("Tracks")
        .font(.system(size: 14))
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .onChange(of: displayInputs, initial: true) { oldInputs, newInputs in
            _ = displayCache.update(
                tracks,
                sortValues: metadata.trackTableSortValues,
                sortValuesRevision: metadata.trackAttributesRevision,
                sortOrder: newInputs.sortOrder
            )
            let search = PlaylistSearch(newInputs.searchQuery)
            visibleRows =
                newInputs.searchQuery.isEmpty
                ? displayCache.rows : displayCache.rows.filter { search.matches($0.track) }
            if oldInputs.searchQuery != newInputs.searchQuery {
                selection.formIntersection(Set(visibleRows.map(\.id)))
            }
            if oldInputs.version != newInputs.version {
                selection = TrackTableDisplayCache.prunedSelection(selection, from: tracks.tracks)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .overlay {
            if !searchQuery.isEmpty && visibleRows.isEmpty {
                ContentUnavailableView.search(text: searchQuery)
            }
        }
    }

    private var displayInputs: TrackTableDisplayInputs {
        TrackTableDisplayInputs(
            version: tracks.version,
            sortValuesRevision: sortOrder.usesTrackAttributes ? metadata.trackAttributesRevision : 0,
            sortOrder: sortOrder,
            searchQuery: searchQuery
        )
    }

    private func isCurrent(_ track: CatalogTrack) -> Bool {
        playback.currentTrackIndicator.trackURI == track.uri
    }

    private func titleCell(_ track: CatalogTrack) -> some View {
        let isCurrentTrack = isCurrent(track)
        let isSelected = selection.contains(track.id)

        return HStack(spacing: 6) {
            if isCurrentTrack {
                if isSelected {
                    Image(systemName: "speaker.wave.2.fill")
                        .accessibilityLabel("Current track")
                } else {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(SpottyPalette.mediaGreen)
                        .accessibilityLabel("Current track")
                }
            }
            if isCurrentTrack && isSelected {
                Text(track.title)
                    .font(.system(size: 16))
                    .lineLimit(1)
            } else {
                Text(track.title)
                    .font(.system(size: 16))
                    .foregroundStyle(isCurrentTrack ? SpottyPalette.mediaGreen : SpottyPalette.textPrimary)
                    .lineLimit(1)
            }
        }
    }

    private func play(_ track: CatalogTrack) {
        guard playback.canStartPlayback else { return }
        playback.playTrack(track)
    }

    private func removeSelectedOccurrences() {
        guard playlistActions?.canRemoveOccurrences == true else { return }
        let selectedTracks = PlaylistMutationSelection.orderedTracks(
            selectedIDs: selection,
            in: visibleRows.map(\.track)
        )
        let uids = PlaylistMutationSelection.occurrenceIDsForRemoval(from: selectedTracks)
        guard !uids.isEmpty else { return }
        playlistActions?.removeOccurrences(uids)
    }
}

private struct TrackTableDisplayInputs: Equatable {
    var version: UUID
    var sortValuesRevision: UInt64
    var sortOrder: [KeyPathComparator<TrackTableRow>]
    var searchQuery: String
}

private extension View {
    @ViewBuilder
    func onDeleteCommandIfAvailable(_ enabled: Bool, perform action: @escaping () -> Void) -> some View {
        if enabled {
            onDeleteCommand(perform: action)
        } else {
            self
        }
    }
}

/// Column placeholder for track details that have not loaded.
private func attributeText(_ value: String?) -> String {
    value ?? "—"
}
