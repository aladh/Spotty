// Concrete projections for detail browsing. The coordinator owns the complete read lifecycle.

import SpottyDomain
import SpottyRuntimeContracts
import Foundation

@MainActor
final class AlbumDetailStore {
    private let detail: CatalogDetailCoordinator

    var item: CatalogItem? { detail.item }
    var trackCollection: CatalogTrackCollection { detail.albumContent.collection }
    var tracks: [CatalogTrack] { trackCollection.tracks }
    var releaseDate: String { detail.albumContent.releaseDate }
    var playCounts: [String: Int64] { detail.albumContent.playCounts }
    var artists: [CatalogItem] { detail.albumContent.artists }
    var isLoading: Bool { detail.isLoading }
    var isLoadingInitialContent: Bool { isLoading && !hasLoadedContent }
    var error: String? { detail.error }
    var isShowingCachedContent: Bool { detail.isShowingCachedContent }
    var freshness: CatalogFreshness { detail.freshness }
    var hasLoadedContent: Bool { detail.hasLoadedContent }

    init(provider: any CatalogProviding, metadata: CatalogMetadataRepository, session: CatalogSessionAvailability) {
        detail = CatalogDetailCoordinator(kind: .album, provider: provider, metadata: metadata, session: session)
    }

    private init(detail: CatalogDetailCoordinator) { self.detail = detail }

    /// Discography owns aggregate publication and one union query; this child owns its reads.
    static func forDiscography(
        provider: any CatalogProviding, session: CatalogSessionAvailability,
        onReplacement: @escaping @MainActor (AlbumDetailStore) -> Void
    ) -> AlbumDetailStore {
        weak var child: AlbumDetailStore?
        let detail = CatalogDetailCoordinator.discographyAlbum(provider: provider, session: session) {
            if let child { onReplacement(child) }
        }
        let result = AlbumDetailStore(detail: detail)
        child = result
        return result
    }

    func applyEntityMetadata(_ entities: [String: CatalogTrackMetadata]) -> Bool {
        detail.applyEntityMetadata(entities)
    }

    func reset() { detail.reset() }
    func prepare(_ selected: CatalogItem) { detail.prepare(selected) }
    func load(_ selected: CatalogItem, force: Bool = false) async {
        await detail.load(selected, force: force)
    }
}

@MainActor
final class ArtistDetailStore {
    /// Separate instances retain the overview and complete discography independently.
    enum Content: CaseIterable, Sendable { case overview, discography }

    private let detail: CatalogDetailCoordinator

    var item: CatalogItem? { detail.item }
    var releases: [CatalogItem] { detail.artistContent.releases }
    var overview: CatalogArtistOverview? { detail.artistContent.overview }
    var releaseKinds: [String: CatalogArtistReleaseKind] { detail.artistContent.releaseKinds }
    var releaseDates: [String: String] { detail.artistContent.releaseDates }
    var popularTracks: CatalogTrackCollection { detail.artistContent.popularTracks }
    var popularPreview: CatalogTrackCollection { detail.artistContent.popularPreview }
    var artistTracks: [String: CatalogArtistPopularTrack] { detail.artistContent.artistTracks }
    var isLoading: Bool { detail.isLoading }
    var error: String? { detail.error }
    var isShowingCachedContent: Bool { detail.isShowingCachedContent }
    var freshness: CatalogFreshness { detail.freshness }

    init(provider: any CatalogProviding, session: CatalogSessionAvailability, content: Content = .overview) {
        detail = CatalogDetailCoordinator(
            kind: content == .overview ? .artistOverview : .artistDiscography,
            provider: provider, session: session)
    }

    func reset() { detail.reset() }
    func prepare(_ selected: CatalogItem) { detail.prepare(selected) }
    func load(_ selected: CatalogItem, force: Bool = false) async {
        await detail.load(selected, force: force)
    }
}
