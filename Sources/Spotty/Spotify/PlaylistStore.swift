import Foundation
import SpottyDomain
import SpottyRuntimeContracts

/// Playlist-specific presentation and playback evidence over the shared detail lifecycle.
@MainActor
final class PlaylistStore {
    private let detail: CatalogDetailCoordinator

    var item: CatalogItem? { detail.item }
    var loadedURI: String? { detail.selection?.uri }
    var trackCollection: CatalogTrackCollection { detail.playlistContent.collection }
    var tracks: [CatalogTrack] { trackCollection.tracks }
    var playbackContents: CatalogPlaylistContents? {
        CatalogPlaylistContents(uri: loadedURI, accountEpoch: detail.contentEpoch, collection: trackCollection)
    }
    var totalDuration: TimeInterval { detail.playlistContent.totalDuration }
    var description: String { detail.playlistContent.description }
    var ownerURI: String? { detail.playlistContent.ownerURI }
    var isLoading: Bool { detail.isLoading }
    var isLoadingInitialContent: Bool { isLoading && !hasLoadedContent }
    var error: String? { detail.error }
    var isShowingCachedContent: Bool { detail.isShowingCachedContent }
    var freshness: CatalogFreshness { detail.freshness }
    var canEditLoadedContent: Bool { detail.isCurrentContent }
    var hasLoadedContent: Bool { detail.hasLoadedContent }

    init(provider: any CatalogProviding, metadata: CatalogMetadataRepository, session: CatalogSessionAvailability) {
        detail = CatalogDetailCoordinator(kind: .playlist, provider: provider, metadata: metadata, session: session)
    }

    func reset() { detail.reset() }
    func invalidateRetainedPlaylist(_ uri: String) { detail.invalidate(uri) }
    func prepare(_ selected: CatalogItem) { detail.prepare(selected) }
    func load(_ selected: CatalogItem, force: Bool = false) async {
        await detail.load(selected, force: force)
    }
}
