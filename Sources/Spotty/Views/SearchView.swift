import SpottyDomain
import SwiftUI

struct SearchView: View {
    let store: SearchStore
    let playback: CatalogPlaybackAccess
    @Binding var searchText: String
    @Bindable var interaction: SearchInteractionState
    let onSelect: (CatalogItem) -> Void
    let playlistActions: TrackPlaylistActions

    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var items: [CatalogItem] {
        switch interaction.filter {
        case .artists: store.artists
        case .albums: store.albums
        case .playlists: store.playlists
        case .all, .songs: []
        }
    }
    private var isEmpty: Bool {
        switch interaction.filter {
        case .all: store.isEmpty
        case .songs: store.tracks.isEmpty
        default: items.isEmpty
        }
    }
    private var error: String? {
        if let section = interaction.filter.section { return store.errors[section] }
        return store.error
    }

    var body: some View {
        VStack(spacing: 0) {
            if !query.isEmpty { filters }
            if query.isEmpty, playback.isConnected || playback.connectionLoadingLabel != nil {
                EmptyState(
                    icon: "magnifyingglass", title: "Search Spotify",
                    message: "Find songs, artists, albums, and playlists."
                )
                .frame(maxHeight: .infinity)
            } else {
                CatalogContentState(
                    isLoading: store.isAwaitingResults(for: query), isEmpty: isEmpty || query.isEmpty,
                    error: error, loadingLabel: "Searching Spotify", errorTitle: "Couldn't load search results",
                    errorIcon: "exclamationmark.magnifyingglass", placeholderPadding: CatalogLayout.contentPadding,
                    connection: playback,
                    connectionMessage: "Connect your Spotify Premium account to search its catalog.",
                    retry: { await store.search(searchText) }
                ) {
                    EmptyState(
                        icon: "magnifyingglass",
                        title:
                            "No \(interaction.filter == .all ? "results" : interaction.filter.rawValue.lowercased()) for “\(query)”",
                        message: "Check your spelling or try different keywords.",
                        actionTitle: interaction.filter != .all && !store.isEmpty ? "Show all results" : nil
                    ) { interaction.filter = .all }
                } content: {
                    VStack(spacing: 0) {
                        if interaction.filter == .all, !store.failedSections.isEmpty {
                            partialFailureBanner
                        }
                        if store.isAwaitingResults(for: query) {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Searching Spotify…").foregroundStyle(SpottyPalette.textSecondary)
                                Spacer()
                            }
                            .padding(.horizontal, CatalogLayout.contentPadding)
                            .padding(.bottom, 12)
                        }
                        results
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .tint(.white)
        .navigationTitle("Search")
        .onChange(of: query, initial: true) { _, query in interaction.prepare(for: query) }
        .catalogTask(id: query, playback: playback) {
            guard playback.isConnected else { return }
            await store.scheduleSearch(searchText)
        }
    }

    private var filters: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { filterButtons }
            NativeHorizontalScroll { HStack(spacing: 8) { filterButtons } }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, CatalogLayout.contentPadding)
        .padding(.vertical, 16)
    }

    private var filterButtons: some View {
        ForEach(SearchFilter.allCases, id: \.self) { filter in
            Button(filter.rawValue) { interaction.filter = filter }
                .font(.system(size: 14))
                .padding(.horizontal, 12)
                .frame(height: 32)
                .foregroundStyle(interaction.filter == filter ? Color.black : SpottyPalette.textPrimary)
                .background(
                    interaction.filter == filter ? Color.white : SpottyPalette.selectedControl, in: Capsule()
                )
                .buttonStyle(.plain)
                .pointingHandCursor()
                .accessibilityLabel("\(filter.rawValue) search results")
                .accessibilityAddTraits(interaction.filter == filter ? .isSelected : [])
        }
    }

    @ViewBuilder private var results: some View {
        switch interaction.filter {
        case .all:
            overview
        case .songs:
            TrackTable(
                tracks: store.trackCollection, playback: playback, variant: .search,
                playlistActions: playlistActions, onSelect: onSelect, interactionState: interaction.songs)
        case .artists, .albums, .playlists:
            resultGrid(filter: interaction.filter)
        }
    }

    private func resultGrid(filter: SearchFilter) -> some View {
        ScrollView {
            LazyVGrid(columns: MediaGridLayout.columns, alignment: .leading, spacing: CatalogLayout.gridSpacing) {
                ForEach(CatalogDisplayOccurrence.identifying(items)) { occurrence in
                    MediaCard(item: occurrence.element, playback: playback, titleLineLimit: 2) {
                        onSelect(occurrence.element)
                    }
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, CatalogLayout.contentPadding)
            .padding(.bottom, CatalogLayout.contentPadding)
        }
        .scrollPosition(
            id: Binding(
                get: { interaction.gridAnchors[filter] },
                set: { interaction.gridAnchors[filter] = $0 })
        )
        .id(filter)
    }

    private var overview: some View {
        let tracks = Array(store.tracks.prefix(4))
        return NativeOccurrenceList(
            rows: overviewRows(tracks: tracks), selection: $interaction.selection,
            accessibilityLabel: "Search results", scrollState: interaction.overviewScroll,
            primaryAction: { ids in
                guard ids.count == 1, let track = tracks.first(where: { ids.contains($0.id) }),
                    playback.canStartPlayback
                else { return }
                playback.playTrack(track)
            },
            contextMenu: { ids in
                trackSelectionMenu(
                    tracks: tracks.filter { ids.contains($0.id) }, playback: playback,
                    playlistActions: playlistActions)
            }
        )
        .onChange(of: store.trackCollection.version) {
            interaction.selection.formIntersection(Set(tracks.map(\.id)))
        }
    }

    private func overviewRows(tracks: [CatalogTrack]) -> [NativeOccurrenceListRow] {
        var rows: [NativeOccurrenceListRow] = []
        if !tracks.isEmpty {
            rows.append(sectionHeader(.songs))
            rows += tracks.map { track in
                NativeOccurrenceListRow(
                    id: track.id, height: 56, drawsHover: true,
                    content: AnyView(
                        SearchSongRow(
                            track: track, playback: playback, isSelected: interaction.selection.contains(track.id),
                            onSelect: onSelect
                        )
                        .padding(.horizontal, CatalogLayout.contentPadding)))
            }
        }
        for (filter, items) in [
            (SearchFilter.artists, store.artists), (.albums, store.albums), (.playlists, store.playlists),
        ] {
            guard !items.isEmpty else { continue }
            rows.append(sectionHeader(filter))
            rows.append(
                NativeOccurrenceListRow(
                    id: "shelf-\(filter.rawValue)", height: 272, isSelectable: false,
                    content: AnyView(
                        MediaCardRow(
                            items: Array(items.prefix(6)), playback: playback, titleLineLimit: 2, onSelect: onSelect
                        )
                        .padding(.horizontal, CatalogLayout.contentPadding))))
        }
        return rows
    }

    private func sectionHeader(_ filter: SearchFilter) -> NativeOccurrenceListRow {
        NativeOccurrenceListRow(
            id: "heading-\(filter.rawValue)", height: 56, isSelectable: false,
            content: AnyView(
                HStack {
                    Text(filter.rawValue).font(.system(size: 24, weight: .bold)).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button("Show all") { interaction.filter = filter }
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(SpottyPalette.textSecondary)
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                        .accessibilityLabel("Show all \(filter.rawValue.lowercased())")
                }
                .padding(.horizontal, CatalogLayout.contentPadding)))
    }

    private var partialFailureBanner: some View {
        HStack(spacing: 10) {
            Label(
                "Some results couldn't load: \(store.failedSections.map { $0 == .tracks ? "Songs" : $0.rawValue.capitalized }.joined(separator: ", "))",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(SpottyPalette.textSecondary)
            Spacer()
            Button("Try Again") { Task { await store.search(searchText) } }.disabled(!playback.isConnected)
        }
        .padding(12)
        .background(SpottyPalette.selectedControl, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, CatalogLayout.contentPadding)
        .padding(.bottom, 12)
    }
}

private struct SearchSongRow: View {
    let track: CatalogTrack
    let playback: CatalogPlaybackAccess
    let isSelected: Bool
    let onSelect: (CatalogItem) -> Void
    @State private var isHovering = false

    var body: some View {
        let indicator = playback.currentTrackIndicator
        let isCurrent = indicator.trackURI == track.uri
        let showsPause = isCurrent && indicator.isPlaying
        let canActivate = playback.canActivateTrack(track)

        HStack(spacing: 12) {
            CatalogCardButton {
                playback.activateTrack(track)
            } label: { isFocused in
                RemoteArtwork(url: track.artworkURL, kind: .track, cornerRadius: 4)
                    .frame(width: 40, height: 40)
                    .overlay {
                        if (isHovering || isFocused) && canActivate {
                            Color.black.opacity(0.5)
                            TransportSymbol(kind: showsPause ? .pause : .play)
                                .frame(width: 20, height: 20).foregroundStyle(.white)
                        }
                    }
            }
            .disabled(!canActivate)
            .pointingHandCursor(enabled: canActivate)
            .accessibilityLabel("\(showsPause ? "Pause" : "Play") \(track.title)")
            .accessibilityValue(isCurrent ? "Current track" : "")
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.system(size: 16))
                    .foregroundStyle(
                        isCurrent && !isSelected
                            ? SpottyPalette.mediaGreen : SpottyPalette.textPrimary)
                CatalogArtistLinks(artists: track.artists, fallback: track.artist, onSelect: onSelect)
                    .font(.system(size: 14))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(formatCatalogDuration(track.duration)).monospacedDigit()
                .font(.system(size: 14)).foregroundStyle(SpottyPalette.textSecondary)
        }
        .lineLimit(1)
        .onHover { isHovering = $0 }
    }
}
