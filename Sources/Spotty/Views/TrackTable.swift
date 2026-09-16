import SpottyDomain
import SpottyRuntimeContracts
import SwiftUI

enum TrackTableVariant: Equatable {
    case catalog
    case playlist
    case album
    case artist

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
    let detailFooter: AnyView?
    let artistTracks: [String: CatalogArtistPopularTrack]
    let playCounts: [String: Int64]
    let detailHeaderCollapseOffset: CGFloat?
    let interactionState: CatalogRouteInteractionState?
    @State private var localInteractionState: CatalogRouteInteractionState
    @State private var projection = TrackTableProjection()

    init(
        tracks: CatalogTrackCollection,
        playback: CatalogPlaybackAccess,
        variant: TrackTableVariant = .catalog,
        searchQuery: String = "",
        playlistActions: TrackPlaylistActions? = nil,
        onSelect: ((CatalogItem) -> Void)? = nil,
        detailHeader: AnyView? = nil,
        compactDetailHeader: AnyView? = nil,
        detailFooter: AnyView? = nil,
        artistTracks: [String: CatalogArtistPopularTrack] = [:],
        playCounts: [String: Int64] = [:],
        detailHeaderCollapseOffset: CGFloat? = nil,
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
        self.detailFooter = detailFooter
        self.artistTracks = artistTracks
        self.playCounts = playCounts
        self.detailHeaderCollapseOffset = detailHeaderCollapseOffset
        self.interactionState = interactionState
        _localInteractionState = State(initialValue: CatalogRouteInteractionState(isPlaylist: variant == .playlist))
    }

    private var interaction: CatalogRouteInteractionState { interactionState ?? localInteractionState }

    var body: some View {
        let visibleRows = projection.rows(tracks, sortOrder: interaction.sortOrder, searchQuery: searchQuery)
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
            detailHeader: detailHeader, compactDetailHeader: compactDetailHeader,
            detailFooter: detailFooter, artistTracks: artistTracks, playCounts: playCounts,
            detailHeaderCollapseOffset: detailHeaderCollapseOffset
        )
        .onChange(of: displayInputs, initial: true) { oldInputs, newInputs in
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

/// Prepare rows synchronously before AppKit lays out a retained route. An empty first render
/// can clamp its saved scroll position before an onChange callback supplies the real rows.
/// This non-observable cache avoids publishing state during body evaluation or reprojection on
/// unrelated SwiftUI updates.
@MainActor
private final class TrackTableProjection {
    private var cache = TrackTableDisplayCache()
    private var searchQuery = ""
    private var visibleRows: [TrackTableRow] = []

    func rows(_ tracks: CatalogTrackCollection, sortOrder: [KeyPathComparator<TrackTableRow>], searchQuery: String)
        -> [TrackTableRow]
    {
        let updated = cache.update(tracks, sortOrder: sortOrder)
        if updated || self.searchQuery != searchQuery {
            self.searchQuery = searchQuery
            let search = PlaylistSearch(searchQuery)
            visibleRows = searchQuery.isEmpty ? cache.rows : cache.rows.filter { search.matches($0.track) }
        }
        return visibleRows
    }
}

private struct TrackTableDisplayInputs: Equatable {
    var version: UUID
    var sortOrder: [KeyPathComparator<TrackTableRow>]
    var searchQuery: String
}
