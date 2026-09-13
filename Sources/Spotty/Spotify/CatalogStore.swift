//
//  CatalogStore.swift
//  Spotty
//
//  Compatibility composition for independently scoped catalog feature stores.
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
    let playlistStore: PlaylistStore
    let albumStore: AlbumDetailStore
    let artistStore: ArtistDetailStore
    let metadata: CatalogMetadataRepository
    let playlistMutations: PlaylistMutationController

    @ObservationIgnored private let session: CatalogSessionAvailability

    init(
        provider: any CatalogProviding,
        playlistMutations: any PlaylistMutating,
        session: CatalogSessionAvailability,
        clock: any PlaybackClock,
        feedback: TransientFeedbackPresenter
    ) {
        self.session = session
        let metadata = CatalogMetadataRepository(session: session)
        self.metadata = metadata
        homeLibrary = HomeLibraryStore(provider: provider, metadata: metadata, session: session)
        searchStore = SearchStore(provider: provider, metadata: metadata, session: session, clock: clock)
        playlistStore = PlaylistStore(provider: provider, metadata: metadata, session: session)
        albumStore = AlbumDetailStore(provider: provider, metadata: metadata, session: session)
        artistStore = ArtistDetailStore(provider: provider, session: session)
        self.playlistMutations = PlaylistMutationController(
            mutations: playlistMutations,
            session: session,
            feedback: feedback,
            playlistStore: playlistStore,
            homeLibrary: homeLibrary
        )
    }

    func reset() {
        homeLibrary.reset()
        searchStore.reset()
        playlistStore.reset()
        albumStore.reset()
        artistStore.reset()
        metadata.reset()
        playlistMutations.reset()
    }

}
