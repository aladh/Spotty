//
//  CatalogStore.swift
//  Spotty
//
//  Composition for independently scoped catalog feature stores.
//

import SpottyDomain
import Foundation

/// Composition owner for independently scoped catalog features. Consumers depend directly on the
/// relevant feature store or metadata repository rather than a broad catalog facade.
@MainActor
@Observable
final class CatalogStore {
    let homeLibrary: HomeLibraryStore
    let searchStore: SearchStore
    private let playlist: PlaylistFeature
    var playlistStore: PlaylistStore { playlist.query }
    let albumStore: AlbumDetailStore
    let artistStore: ArtistDetailStore
    let discographyStore: DiscographyStore
    let metadata: CatalogMetadataRepository
    var playlistMutations: PlaylistMutationController { playlist.mutations }

    init(
        provider: any CatalogProviding,
        playlistMutations: any PlaylistMutating,
        session: CatalogSessionAvailability,
        clock: any PlaybackClock,
        feedback: TransientFeedbackPresenter
    ) {
        let metadata = CatalogMetadataRepository(session: session)
        self.metadata = metadata
        homeLibrary = HomeLibraryStore(provider: provider, metadata: metadata, session: session)
        searchStore = SearchStore(provider: provider, metadata: metadata, session: session, clock: clock)
        albumStore = AlbumDetailStore(provider: provider, metadata: metadata, session: session)
        artistStore = ArtistDetailStore(provider: provider, session: session)
        discographyStore = DiscographyStore(provider: provider, metadata: metadata, session: session)
        playlist = PlaylistFeature(
            provider: provider, metadata: metadata, session: session,
            mutations: playlistMutations, homeLibrary: homeLibrary, feedback: feedback)
    }

    func reset() {
        homeLibrary.reset()
        searchStore.reset()
        playlist.reset()
        albumStore.reset()
        artistStore.reset()
        discographyStore.reset()
        metadata.reset()
    }

}
