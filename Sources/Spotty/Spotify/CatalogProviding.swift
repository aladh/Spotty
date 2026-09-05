//
//  CatalogProviding.swift
//  Spotty
//
//  Replaceable service boundaries for Spotify catalog reads and enrichment.
//

import SpottyDomain
import Foundation

nonisolated protocol CatalogProviding: Sendable {
    func searchTracks(_ term: String, limit: Int) async throws -> [PathfinderTrack]
    func searchAlbums(_ term: String, limit: Int) async throws -> [PathfinderAlbum]
    func searchArtists(_ term: String, limit: Int) async throws -> [PathfinderArtist]
    func searchPlaylists(_ term: String, limit: Int) async throws -> [PathfinderPlaylist]
    func home() async throws -> PathfinderHome
    func libraryPlaylists() async throws -> [PathfinderPlaylist]
    func playlistLibrary() async throws -> [PlaylistLibraryNode]
    func libraryAlbums() async throws -> [PathfinderAlbum]
    func libraryArtists() async throws -> [PathfinderArtist]
    func libraryTracks() async throws -> [PathfinderLibraryTrackItem]
    func profile() async throws -> PathfinderProfile
    func playlist(id: String) async throws -> PathfinderPlaylistUnion
    func album(id: String) async throws -> PathfinderAlbumUnion
    func artist(id: String) async throws -> PathfinderArtistUnion
    func artistDiscography(id: String) async throws -> PathfinderArtistUnion
}

extension PartnerAPI: CatalogProviding {}

nonisolated enum CatalogProviderCapabilityError: Error {
    case unsupported
}

extension CatalogProviding {
    /// Flat fallback for providers without folder support; PartnerAPI supplies the full hierarchy.
    func playlistLibrary() async throws -> [PlaylistLibraryNode] {
        try await libraryPlaylists().compactMap(CatalogMapping.item(from:)).map(PlaylistLibraryNode.init(playlist:))
    }

    func searchAlbums(_: String, limit _: Int) async throws -> [PathfinderAlbum] {
        throw CatalogProviderCapabilityError.unsupported
    }

    func searchArtists(_: String, limit _: Int) async throws -> [PathfinderArtist] {
        throw CatalogProviderCapabilityError.unsupported
    }

    func searchPlaylists(_: String, limit _: Int) async throws -> [PathfinderPlaylist] {
        throw CatalogProviderCapabilityError.unsupported
    }

    func album(id _: String) async throws -> PathfinderAlbumUnion {
        throw CatalogProviderCapabilityError.unsupported
    }

    func artist(id _: String) async throws -> PathfinderArtistUnion {
        throw CatalogProviderCapabilityError.unsupported
    }

    func artistDiscography(id _: String) async throws -> PathfinderArtistUnion {
        throw CatalogProviderCapabilityError.unsupported
    }
}

nonisolated protocol TrackAttributesProviding: Sendable {
    func attributes(for uris: [String]) async throws -> [String: TrackAttributes]
}

extension TrackAttributesAPI: TrackAttributesProviding {}

nonisolated struct CatalogSessionSnapshot: Equatable, Sendable {
    let accountEpoch: UInt64
    let isAvailable: Bool
    let revision: UInt64
}

/// Account-scoped catalog work captures this value before suspension and revalidates it before
/// every write. A Boolean alone is insufficient because two different accounts can both be ready.
@MainActor
final class CatalogSessionAvailability {
    private(set) var snapshot: CatalogSessionSnapshot

    init(accountEpoch: UInt64 = 1, isAvailable: Bool = false) {
        snapshot = CatalogSessionSnapshot(
            accountEpoch: accountEpoch,
            isAvailable: isAvailable,
            revision: 0
        )
    }

    var isAvailable: Bool { snapshot.isAvailable }
    var accountEpoch: UInt64 { snapshot.accountEpoch }

    func update(accountEpoch: UInt64, isAvailable: Bool) {
        guard snapshot.accountEpoch != accountEpoch || snapshot.isAvailable != isAvailable else { return }
        snapshot = CatalogSessionSnapshot(
            accountEpoch: accountEpoch,
            isAvailable: isAvailable,
            revision: snapshot.revision &+ 1
        )
    }

    func requestIdentity(requestID: UInt64) -> AccountScopedRequestIdentity {
        AccountScopedRequestIdentity(
            requestID: requestID,
            accountEpoch: snapshot.accountEpoch,
            sessionRevision: snapshot.revision
        )
    }
}
