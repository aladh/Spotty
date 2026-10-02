import Foundation
import Observation
import SpottyDomain
import SpottyRuntimeContracts

/// Album children own cached/live loading. This artist scope owns their bounded retention,
/// aggregate metadata and one entity query, including publication while a refresh is pending.
@MainActor
@Observable
final class DiscographyStore {
    let artist: ArtistDetailStore
    private(set) var artistURI: String?
    private(set) var albums: [String: AlbumDetailStore] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var contentEpoch: UInt64
    @ObservationIgnored private let clock: any PlaybackClock
    @ObservationIgnored private let provider: any CatalogProviding
    @ObservationIgnored private let session: CatalogSessionAvailability
    @ObservationIgnored private let metadata: CatalogMetadataRepository
    @ObservationIgnored private let entityObservation: CatalogEntityObservation

    init(
        provider: any CatalogProviding, metadata: CatalogMetadataRepository, session: CatalogSessionAvailability,
        clock: any PlaybackClock
    ) {
        self.clock = clock
        self.provider = provider
        self.metadata = metadata
        self.session = session
        contentEpoch = session.accountEpoch
        artist = ArtistDetailStore(provider: provider, session: session, content: .discography, clock: clock)
        entityObservation = CatalogEntityObservation(provider: provider, session: session)
    }

    func prepare(artistURI: String) {
        guard self.artistURI != artistURI || contentEpoch != session.accountEpoch else { return }
        resetAlbums()
        self.artistURI = artistURI
    }

    func reset() {
        artist.reset()
        resetAlbums()
        artistURI = nil
    }

    private func resetAlbums() {
        entityObservation.reset()
        let retired = albums.values
        albums = [:]
        order = []
        contentEpoch = session.accountEpoch
        retired.forEach { $0.reset() }
        publishMetadata()
    }

    func load(_ item: CatalogItem, artistURI: String) async {
        guard !Task.isCancelled, item.kind == .album, self.artistURI == artistURI else { return }
        prepare(artistURI: artistURI)
        let album: AlbumDetailStore
        let wasRetained = albums[item.uri] != nil
        if let retained = albums[item.uri] {
            album = retained
        } else {
            album = AlbumDetailStore.forDiscography(provider: provider, session: session, clock: clock) {
                [weak self] child in
                self?.contentReplaced(child, uri: item.uri)
            }
            albums[item.uri] = album
        }
        order.removeAll { $0 == item.uri }
        order.append(item.uri)
        trim()
        album.prepare(item)
        // New children publish during prepare. A retained touch can change aggregate precedence
        // or retry a failed query without replacing its content.
        if wasRetained {
            publishMetadata()
            updateEntityObservation()
        }
        await album.load(item)
    }

    private func contentReplaced(_ child: AlbumDetailStore, uri: String) {
        guard contentEpoch == session.accountEpoch, albums[uri] === child else { return }
        // A whole collection supersedes old entity reads even when its URI set is unchanged.
        entityObservation.reset()
        trim()
        publishMetadata()
        updateEntityObservation()
    }

    private func trim() {
        while order.count > 1 && (order.count > 20 || albums.values.reduce(0, { $0 + $1.tracks.count }) > 20_000) {
            let uri = order.removeFirst()
            albums.removeValue(forKey: uri)?.reset()
        }
    }

    private func updateEntityObservation() {
        entityObservation.update(collections: albums.values.map(\.trackCollection)) { [weak self] entities in
            guard let self, contentEpoch == session.accountEpoch else { return }
            var changed = false
            for album in albums.values {
                if album.applyEntityMetadata(entities) { changed = true }
            }
            if changed { publishMetadata() }
        }
    }

    private func publishMetadata() {
        metadata.replaceTracks(order.flatMap { albums[$0]?.tracks ?? [] }, from: .discography)
    }
}
