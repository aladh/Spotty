import SpottyDomain

/// Catalog playlist writes available to track tables without Pathfinder DTOs.
struct TrackPlaylistActions {
    let editablePlaylists: [CatalogItem]
    let canRemoveOccurrences: Bool
    let addToPlaylist: @MainActor (CatalogItem, [CatalogTrack]) -> Void
    /// Selected display occurrence IDs. The mutation owner resolves explicit server UIDs.
    let removeOccurrences: @MainActor ([String]) -> Void
}
