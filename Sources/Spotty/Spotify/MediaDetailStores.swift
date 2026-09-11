//
//  MediaDetailStores.swift
//  Spotty
//
//  Account- and selection-scoped album and artist browsing state.
//

import SpottyDomain
import Foundation

@MainActor
@Observable
final class AlbumDetailStore {
    private typealias Flight = AccountScopedSingleFlight<String>

    private(set) var item: CatalogItem?
    private(set) var trackCollection = CatalogTrackCollection()
    var tracks: [CatalogTrack] { trackCollection.tracks }
    private(set) var releaseDate = ""
    private(set) var isLoading = false
    private(set) var error: String?

    @ObservationIgnored private let provider: any CatalogProviding
    @ObservationIgnored private let metadata: CatalogMetadataRepository
    @ObservationIgnored private let session: CatalogSessionAvailability
    @ObservationIgnored private let flight: Flight

    init(provider: any CatalogProviding, metadata: CatalogMetadataRepository, session: CatalogSessionAvailability) {
        self.provider = provider
        self.metadata = metadata
        self.session = session
        flight = Flight(session: session, join: .joinMatchingKey, scope: .singleSelection, publish: .strict)
    }

    func reset() {
        flight.reset()
        item = nil
        trackCollection.replace([])
        releaseDate = ""
        isLoading = false
        error = nil
    }

    func load(_ selected: CatalogItem) async {
        guard session.isAvailable, selected.kind == .album else { return }
        switch flight.admit(selected.uri) {
        case .skip:
            return
        case let .join(claim):
            await flight.awaitFlight(claim)
        case let .start(handle):
            item = selected
            trackCollection.replace([])
            releaseDate = ""
            error = nil
            isLoading = true
            guard let id = SpotifyURI.id(from: selected.uri, kind: "album") else {
                error = "Spotify returned an invalid album address."
                isLoading = false
                flight.abandonUnstarted(handle)
                return
            }
            await flight.run(handle) { [weak self] in
                guard let self else { return }
                defer {
                    if self.flight.owns(handle) {
                        isLoading = false
                    }
                }
                do {
                    let album = try await provider.album(id: id)
                    guard self.isCurrent(handle) else { return }
                    trackCollection.replace(
                        album.tracks.compactMap { CatalogMapping.albumTrack(from: $0, album: album) }
                    )
                    releaseDate = album.date?.day ?? ""
                    self.flight.markLoaded(handle)
                    metadata.replaceTracks(tracks, from: .album)
                    metadata.loadTrackAttributes(for: tracks)
                } catch {
                    guard !isCancellation(error), self.isCurrent(handle) else {
                        return
                    }
                    self.error = error.localizedDescription
                }
            }
        }
    }

    private func isCurrent(_ handle: Flight.Handle) -> Bool {
        item?.uri == handle.key && flight.isCurrent(handle)
    }
}

@MainActor
@Observable
final class ArtistDetailStore {
    private typealias Flight = AccountScopedSingleFlight<String>

    private(set) var item: CatalogItem?
    private(set) var releases: [CatalogItem] = []
    private(set) var isLoading = false
    private(set) var error: String?

    @ObservationIgnored private let provider: any CatalogProviding
    @ObservationIgnored private let session: CatalogSessionAvailability
    @ObservationIgnored private let flight: Flight

    init(provider: any CatalogProviding, session: CatalogSessionAvailability) {
        self.provider = provider
        self.session = session
        flight = Flight(session: session, join: .joinMatchingKey, scope: .singleSelection, publish: .strict)
    }

    func reset() {
        flight.reset()
        item = nil
        releases = []
        isLoading = false
        error = nil
    }

    func load(_ selected: CatalogItem) async {
        guard session.isAvailable, selected.kind == .artist else { return }
        switch flight.admit(selected.uri) {
        case .skip:
            return
        case let .join(claim):
            await flight.awaitFlight(claim)
        case let .start(handle):
            item = selected
            releases = []
            error = nil
            isLoading = true
            guard let id = SpotifyURI.id(from: selected.uri, kind: "artist") else {
                error = "Spotify returned an invalid artist address."
                isLoading = false
                flight.abandonUnstarted(handle)
                return
            }
            await flight.run(handle) { [weak self] in
                guard let self else { return }
                defer {
                    if self.flight.owns(handle) {
                        isLoading = false
                    }
                }
                do {
                    async let overview = provider.artist(id: id)
                    async let discography = provider.artistDiscography(id: id)
                    let (profile, allReleases) = try await (overview, discography)
                    guard self.isCurrent(handle) else { return }
                    let artistName = profile.profile?.name ?? selected.title
                    releases = allReleases.releases.compactMap { CatalogMapping.item(from: $0, artist: artistName) }
                    self.flight.markLoaded(handle)
                } catch {
                    guard !isCancellation(error), self.isCurrent(handle) else {
                        return
                    }
                    self.error = error.localizedDescription
                }
            }
        }
    }

    private func isCurrent(_ handle: Flight.Handle) -> Bool {
        item?.uri == handle.key && flight.isCurrent(handle)
    }
}
