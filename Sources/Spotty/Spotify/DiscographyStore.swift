import Foundation
import Observation
import SpottyDomain
import SpottyRuntimeContracts

/// Visible releases reuse the album store's admission, freshness and metadata behavior.
/// Keep a bounded set for this artist; the native list retains its visible anchor on eviction.
@MainActor
@Observable
final class DiscographyStore {
    let artist: ArtistDetailStore
    private(set) var artistURI: String?
    private(set) var albums: [String: AlbumDetailStore] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private let makeAlbum: () -> AlbumDetailStore
    @ObservationIgnored private let metadata: CatalogMetadataRepository

    init(provider: any CatalogProviding, metadata: CatalogMetadataRepository, session: CatalogSessionAvailability) {
        self.metadata = metadata
        artist = ArtistDetailStore(provider: provider, session: session, content: .discography)
        makeAlbum = {
            AlbumDetailStore(
                provider: provider, metadata: CatalogMetadataRepository(session: session), session: session)
        }
    }

    func prepare(artistURI: String) {
        guard self.artistURI != artistURI else { return }
        resetAlbums()
        self.artistURI = artistURI
    }

    func reset() {
        artist.reset()
        resetAlbums()
        artistURI = nil
    }

    private func resetAlbums() {
        albums.values.forEach { $0.reset() }
        albums = [:]
        order = []
        publishMetadata()
    }

    func load(_ item: CatalogItem, artistURI: String) async {
        guard self.artistURI == artistURI else { return }
        let album = albums[item.uri] ?? makeAlbum()
        album.prepare(item)
        albums[item.uri] = album
        order.removeAll { $0 == item.uri }
        order.append(item.uri)
        trim()
        await album.load(item)
        guard self.artistURI == artistURI, albums[item.uri] === album else { return }
        trim()
        publishMetadata()
    }

    private func trim() {
        while order.count > 1 && (order.count > 20 || albums.values.reduce(0, { $0 + $1.tracks.count }) > 20_000) {
            let uri = order.removeFirst()
            albums.removeValue(forKey: uri)?.reset()
        }
    }

    private func publishMetadata() {
        metadata.replaceTracks(order.flatMap { albums[$0]?.tracks ?? [] }, from: .discography)
    }
}
