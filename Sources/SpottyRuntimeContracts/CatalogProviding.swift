import Foundation
import SpottyDomain

/// Domain values returned by catalog reads. Private Spotify response shapes stay in the gateway.
public protocol CatalogProviding: Sendable {
    func searchTracks(_ term: String, limit: Int) async throws -> [CatalogTrack]
    func searchAlbums(_ term: String, limit: Int) async throws -> [CatalogItem]
    func searchArtists(_ term: String, limit: Int) async throws -> [CatalogItem]
    func searchPlaylists(_ term: String, limit: Int) async throws -> [CatalogItem]
    func home() async throws -> CatalogHomeSnapshot
    func playlistLibrary() async throws -> [PlaylistLibraryNode]
    func libraryAlbums() async throws -> [CatalogItem]
    func libraryArtists() async throws -> [CatalogItem]
    func libraryTracks() async throws -> [CatalogTrack]
    func profile() async throws -> CatalogProfileSnapshot
    func playlist(id: String) async throws -> CatalogPlaylistSnapshot
    func album(id: String) async throws -> CatalogAlbumSnapshot
    func artist(id: String) async throws -> CatalogArtistSnapshot
    func artistDiscography(id: String) async throws -> CatalogArtistSnapshot
}

public enum CatalogProviderCapabilityError: Error { case unsupported }

extension CatalogProviding {
    public func searchAlbums(_: String, limit _: Int) async throws -> [CatalogItem] {
        throw CatalogProviderCapabilityError.unsupported
    }
    public func searchArtists(_: String, limit _: Int) async throws -> [CatalogItem] {
        throw CatalogProviderCapabilityError.unsupported
    }
    public func searchPlaylists(_: String, limit _: Int) async throws -> [CatalogItem] {
        throw CatalogProviderCapabilityError.unsupported
    }
    public func album(id _: String) async throws -> CatalogAlbumSnapshot {
        throw CatalogProviderCapabilityError.unsupported
    }
    public func artist(id _: String) async throws -> CatalogArtistSnapshot {
        throw CatalogProviderCapabilityError.unsupported
    }
    public func artistDiscography(id _: String) async throws -> CatalogArtistSnapshot {
        throw CatalogProviderCapabilityError.unsupported
    }
}

public struct CatalogHomeSnapshot: Equatable, Codable, Sendable {
    public let greeting: String
    public let sections: [CatalogSection]
    public init(greeting: String, sections: [CatalogSection]) {
        self.greeting = greeting
        self.sections = sections
    }
}

public struct CatalogProfileSnapshot: Equatable, Codable, Sendable {
    public let name: String
    public let uri: String?
    public init(name: String, uri: String?) { self.name = name; self.uri = uri }
}

/// Cached catalog content remains useful for browsing, but never establishes write permission.
public enum CatalogFreshness: Equatable, Codable, Sendable {
    case current
    case cached(fetchedAt: Date)

    public var isCurrent: Bool {
        if case .current = self { return true }
        return false
    }
}

public struct CatalogPlaylistSnapshot: Equatable, Codable, Sendable {
    public let freshness: CatalogFreshness
    public let item: CatalogItem?
    public let description: String
    public let ownerURI: String?
    public let tracks: [CatalogTrack]
    public init(
        description: String, ownerURI: String?, tracks: [CatalogTrack], item: CatalogItem? = nil,
        freshness: CatalogFreshness = .current
    ) {
        self.item = item
        self.freshness = freshness
        self.description = description
        self.ownerURI = ownerURI
        self.tracks = tracks
    }
}

public struct CatalogAlbumSnapshot: Equatable, Codable, Sendable {
    public let freshness: CatalogFreshness
    public let item: CatalogItem?
    public let tracks: [CatalogTrack]
    public let releaseDate: String
    public init(
        tracks: [CatalogTrack], releaseDate: String, item: CatalogItem? = nil, freshness: CatalogFreshness = .current
    ) {
        self.item = item
        self.freshness = freshness
        self.tracks = tracks
        self.releaseDate = releaseDate
    }
}

public struct CatalogArtistSnapshot: Equatable, Codable, Sendable {
    public let freshness: CatalogFreshness
    public let item: CatalogItem?
    public let name: String?
    public let releases: [CatalogItem]
    public init(
        name: String?, releases: [CatalogItem], item: CatalogItem? = nil, freshness: CatalogFreshness = .current
    ) { self.name = name; self.releases = releases; self.item = item; self.freshness = freshness }
}

/// Every attribute is optional: unavailable enrichment cannot remove playable tracks.
public struct TrackAttributes: Equatable, Codable, Sendable {
    public let popularity: Int?
    public let bpm: Int?
    public let key: String?
    public init(popularity: Int?, bpm: Int?, key: String?) {
        self.popularity = popularity
        self.bpm = bpm
        self.key = key
    }
}

public protocol TrackAttributesProviding: Sendable {
    func attributes(for uris: [String]) async throws -> [String: TrackAttributes]
}

public protocol PlaylistMutating: Sendable {
    func addToPlaylist(playlistId: String, trackUris: [String]) async throws
    func removeFromPlaylist(playlistId: String, uids: [String]) async throws
    func addToPlaylist(playlistId: String, trackUris: [String], context: PlaylistMutationContext) async throws
    func removeFromPlaylist(playlistId: String, uids: [String], context: PlaylistMutationContext) async throws
}

extension PlaylistMutating {
    public func addToPlaylist(playlistId: String, trackUris: [String], context: PlaylistMutationContext) async throws {
        try await addToPlaylist(playlistId: playlistId, trackUris: trackUris)
    }

    public func removeFromPlaylist(playlistId: String, uids: [String], context: PlaylistMutationContext) async throws {
        try await removeFromPlaylist(playlistId: playlistId, uids: uids)
    }
}

/// Compatibility failures have stable meaning without exposing endpoint names or raw responses.
public enum CatalogReadFailure: Error, Equatable, Sendable {
    case compatibility
    case sessionExpired
    case offline
    case timedOut
    case throttled
    case unavailable
}
