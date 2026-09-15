import SpottyDomain
import SwiftUI

enum TrackTableVariant: Equatable {
    case catalog
    case playlist
    case album

    var initialSortOrder: [KeyPathComparator<TrackTableRow>] {
        switch self {
        case .catalog, .album:
            []
        case .playlist:
            [KeyPathComparator(\TrackTableRow.dateAddedSortValue, order: .reverse)]
        }
    }
}

/// Shared occurrence projection for the directly owned native track tables.
/// Selection and sorting stay in presentation state; AppKit owns control tracking and scrolling.
struct TrackTable: View {
    let tracks: CatalogTrackCollection
    let playback: CatalogPlaybackAccess
    let variant: TrackTableVariant
    let searchQuery: String
    var playlistActions: TrackPlaylistActions?
    let onSelect: ((CatalogItem) -> Void)?
    let detailHeader: AnyView?
    let compactDetailHeader: AnyView?
    let interactionState: CatalogRouteInteractionState?
    @State private var localInteractionState: CatalogRouteInteractionState
    @State private var displayCache = TrackTableDisplayCache()
    @State private var visibleRows: [TrackTableRow] = []

    init(
        tracks: CatalogTrackCollection,
        playback: CatalogPlaybackAccess,
        variant: TrackTableVariant = .catalog,
        searchQuery: String = "",
        playlistActions: TrackPlaylistActions? = nil,
        onSelect: ((CatalogItem) -> Void)? = nil,
        detailHeader: AnyView? = nil,
        compactDetailHeader: AnyView? = nil,
        interactionState: CatalogRouteInteractionState? = nil
    ) {
        self.tracks = tracks
        self.playback = playback
        self.variant = variant
        self.searchQuery = searchQuery
        self.playlistActions = playlistActions
        self.onSelect = onSelect
        self.detailHeader = detailHeader
        self.compactDetailHeader = compactDetailHeader
        self.interactionState = interactionState
        _localInteractionState = State(initialValue: CatalogRouteInteractionState(isPlaylist: variant == .playlist))
    }

    private var interaction: CatalogRouteInteractionState { interactionState ?? localInteractionState }

    var body: some View {
        // Register the presentation dependency here: AppKit reads the binding outside a
        // SwiftUI body, including immediate menu actions after a native selection change.
        let _ = interaction.selection
        NativeTrackTable(
            rows: visibleRows, variant: variant, playback: playback,
            searchQuery: searchQuery,
            selection: Binding(get: { interaction.selection }, set: { interaction.selection = $0 }),
            sortOrder: Binding(get: { interaction.sortOrder }, set: { interaction.sortOrder = $0 }),
            scrollOffset: Binding(get: { interaction.scrollOffset }, set: { interaction.scrollOffset = $0 }),
            playlistActions: playlistActions, onSelect: onSelect,
            detailHeader: detailHeader, compactDetailHeader: compactDetailHeader
        )
        .onChange(of: displayInputs, initial: true) { oldInputs, newInputs in
            _ = displayCache.update(
                tracks,
                sortOrder: newInputs.sortOrder
            )
            let search = PlaylistSearch(newInputs.searchQuery)
            visibleRows =
                newInputs.searchQuery.isEmpty
                ? displayCache.rows : displayCache.rows.filter { search.matches($0.track) }
            if oldInputs.searchQuery != newInputs.searchQuery {
                interaction.selection.formIntersection(Set(visibleRows.map(\.id)))
            }
            if oldInputs.version != newInputs.version {
                interaction.selection = TrackTableDisplayCache.prunedSelection(
                    interaction.selection, from: tracks.tracks)
            }
        }
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
            sortOrder: interaction.sortOrder,
            searchQuery: searchQuery
        )
    }
}

private struct TrackTableDisplayInputs: Equatable {
    var version: UUID
    var sortOrder: [KeyPathComparator<TrackTableRow>]
    var searchQuery: String
}
