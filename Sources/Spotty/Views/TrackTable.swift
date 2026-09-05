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
    @State private var playlistHeaderHeight: CGFloat = 0
    @State private var showsCompactHeader = false
    @State private var selection: Set<CatalogTrack.ID> = []
    @State private var sortOrder: [KeyPathComparator<TrackTableRow>] = []
    @State private var displayCache = TrackTableDisplayCache()

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
                GeometryReader { geometry in
                    playlistList(width: geometry.size.width)
                }
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
            if oldInputs.version != newInputs.version {
                selection = TrackTableDisplayCache.prunedSelection(selection, from: tracks.tracks)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .onChange(of: searchQuery) {
            selection.formIntersection(Set(visibleRows.map(\.id)))
        }
        .overlay {
            if !searchQuery.isEmpty && visibleRows.isEmpty {
                ContentUnavailableView.search(text: searchQuery)
            }
        }
    }

    private var visibleRows: [TrackTableRow] {
        guard !searchQuery.isEmpty else { return displayCache.rows }
        let search = PlaylistSearch(searchQuery)
        return displayCache.rows.filter { search.matches($0.track) }
    }

    private var displayInputs: TrackTableDisplayInputs {
        TrackTableDisplayInputs(
            version: tracks.version,
            sortValuesRevision: sortOrder.usesTrackAttributes ? metadata.trackAttributesRevision : 0,
            sortOrder: sortOrder
        )
    }

    private func isCurrent(_ track: CatalogTrack) -> Bool {
        playback.currentTrackIndicator.trackURI == track.uri
    }

    private func playlistIndexCell(_ row: TrackTableRow, position: Int, total: Int) -> some View {
        let currentTrackIndicator = playback.currentTrackIndicator
        let isCurrentTrack = currentTrackIndicator.trackURI == row.track.uri
        let isSelected = selection.contains(row.id)
        let indexForeground: Color = isSelected ? SpottyPalette.textPrimary : SpottyPalette.mediaGreen

        return Group {
            if isCurrentTrack && currentTrackIndicator.isPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(indexForeground)
                    .accessibilityLabel("Current track, track \(position) of \(total)")
            } else if isCurrentTrack {
                Text(String(position))
                    .monospacedDigit()
                    .foregroundStyle(indexForeground)
                    .accessibilityLabel("Current track, track \(position) of \(total)")
            } else {
                Text(String(position))
                    .monospacedDigit()
                    .foregroundStyle(SpottyPalette.dataText)
                    .accessibilityLabel("Track \(position) of \(total)")
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, minHeight: CatalogLayout.playlistRowContentHeight, alignment: .trailing)
    }

    private func playlistTitleCell(_ track: CatalogTrack) -> some View {
        let isCurrentTrack = isCurrent(track)
        let isSelected = selection.contains(track.id)
        let titleForeground: Color =
            isCurrentTrack && !isSelected ? SpottyPalette.mediaGreen : SpottyPalette.textPrimary
        let artistForeground: Color =
            isCurrentTrack && !isSelected ? SpottyPalette.mediaGreen : SpottyPalette.textSecondary

        return HStack(alignment: .center, spacing: 12) {
            RemoteArtwork(
                url: track.artworkURL,
                kind: .track,
                cornerRadius: 4,
                pointSize: 40
            )
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 1) {
                Text(PlaylistSearch(searchQuery).highlighted(track.title))
                    .font(.system(size: 16))
                    .foregroundStyle(titleForeground)
                    .lineLimit(1)
                CatalogArtistLinks(
                    artists: track.artists, fallback: track.artist, color: artistForeground,
                    searchQuery: searchQuery, onSelect: onSelect
                )
                .font(.system(size: 14))
            }
        }
        .frame(maxWidth: .infinity, minHeight: CatalogLayout.playlistRowContentHeight, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func playlistList(width: CGFloat) -> some View {
        let rows = visibleRows
        let indexWidth = max(24, CGFloat(String(max(1, rows.count)).count) * 9)
        let flexibleWidth = max(400, width - 48 - 176 - indexWidth)
        let titleWidth = flexibleWidth / 2
        let detailWidth = flexibleWidth / 4
        let columnHeader =
            HStack(spacing: 16) {
                Text("#").frame(width: indexWidth, alignment: .trailing)
                playlistColumnHeader("Title", index: 1, keyPath: \TrackTableRow.title)
                    .frame(width: titleWidth, alignment: .leading)
                playlistColumnHeader("Album", index: 2, keyPath: \TrackTableRow.album)
                    .frame(width: detailWidth, alignment: .leading)
                playlistColumnHeader("Date added", index: 3, keyPath: \TrackTableRow.dateAddedSortValue)
                    .frame(width: detailWidth, alignment: .leading)
                Button {
                    sortPlaylistColumn(4)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "clock").font(.system(size: 16))
                        if let comparator = sortOrder.first, comparator.keyPath == \TrackTableRow.duration {
                            Image(
                                systemName: comparator.order == .forward
                                    ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill"
                            )
                            .font(.system(size: 8))
                            .foregroundStyle(SpottyPalette.mediaGreen)
                        }
                    }
                    .frame(width: 80, alignment: .center)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Sort by duration")
            }
            .font(.system(size: 14))
            .foregroundStyle(SpottyPalette.dataText)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .overlay(alignment: .bottom) { Color.white.opacity(0.1).frame(height: 1) }

            .padding(.horizontal, 24)
            .background(Color(white: 0.122))

        return List(selection: $selection) {
            if let playlistHeader {
                playlistHeader
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height
                    } action: {
                        playlistHeaderHeight = $0
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
                    .background {
                        PlaylistScrollObserver(threshold: playlistHeaderHeight - 64) {
                            showsCompactHeader = $0
                        }
                    }
            }
            columnHeader
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .selectionDisabled()

            ForEach(Array(rows.enumerated()), id: \.element.id) { offset, row in
                HStack(spacing: 16) {
                    playlistIndexCell(row, position: offset + 1, total: rows.count).frame(width: indexWidth)
                    playlistTitleCell(row.track).frame(width: titleWidth, alignment: .leading)
                    CatalogTextLink(
                        title: row.track.album, item: row.track.albumItem,
                        color: SpottyPalette.dataText, searchQuery: searchQuery, onSelect: onSelect
                    )
                    .frame(width: detailWidth, alignment: .leading)
                    Text(formatPlaylistDateAdded(row.track.addedAt))
                        .foregroundStyle(SpottyPalette.dataText)
                        .lineLimit(1)
                        .frame(width: detailWidth, alignment: .leading)
                    Text(formatCatalogDuration(row.track.duration))
                        .foregroundStyle(SpottyPalette.dataText)
                        .monospacedDigit()
                        .frame(width: 80, alignment: .center)
                }
                .frame(height: 40)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .modifier(PlaylistTrackRowHighlight(isSelected: selection.contains(row.id)))
                .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 24))
                .listRowSeparator(.hidden)
                .tag(row.id)
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
        .overlay(alignment: .top) {
            if showsCompactHeader, let compactPlaylistHeader {
                VStack(spacing: 0) {
                    compactPlaylistHeader
                    columnHeader
                }
            }
        }
    }

    private func playlistColumnHeader<Value>(
        _ title: String, index: Int, keyPath: KeyPath<TrackTableRow, Value> & Sendable
    ) -> some View {
        Button {
            sortPlaylistColumn(index)
        } label: {
            HStack(spacing: 8) {
                Text(title)
                if let comparator = sortOrder.first, comparator.keyPath == keyPath {
                    Image(
                        systemName: comparator.order == .forward ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill"
                    )
                    .font(.system(size: 8))
                    .foregroundStyle(SpottyPalette.mediaGreen)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sort by \(title)")
    }

    private func sortPlaylistColumn(_ index: Int) {
        let columns = [
            KeyPathComparator(\TrackTableRow.title),
            KeyPathComparator(\TrackTableRow.album),
            KeyPathComparator(\TrackTableRow.dateAddedSortValue),
            KeyPathComparator(\TrackTableRow.duration),
        ]
        guard (1...columns.count).contains(index) else { return }
        var comparator = columns[index - 1]
        if let current = sortOrder.first, current.keyPath == comparator.keyPath {
            comparator.order = current.order == .forward ? .reverse : .forward
        }
        sortOrder = [comparator]
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

private struct PlaylistTrackRowHighlight: ViewModifier {
    let isSelected: Bool
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                Color.white.opacity(isSelected ? 0.2 : (isHovering ? 0.1 : 0)),
                in: RoundedRectangle(cornerRadius: 4)
            )
            .background { PlaylistSelectionAppearance() }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active: if !isHovering { isHovering = true }
                case .ended: isHovering = false
                }
            }
            .onDisappear { isHovering = false }
    }
}
