import Foundation
import SpottyDomain

public enum CatalogArtistReleaseKind: String, Codable, Sendable {
    case album, single, ep, compilation

    public var label: String {
        switch self {
        case .album: "Album"
        case .single: "Single"
        case .ep: "EP"
        case .compilation: "Compilation"
        }
    }
}

public struct CatalogArtistPopularTrack: Equatable, Codable, Sendable {
    public let track: CatalogTrack
    public let playCount: Int64?
    public let isPlayable: Bool

    public init(track: CatalogTrack, playCount: Int64? = nil, isPlayable: Bool = true) {
        self.track = track
        self.playCount = playCount
        self.isPlayable = isPlayable
    }
}

/// Optional artist-page facts from the overview, separate from the complete discography.
public struct CatalogArtistOverview: Equatable, Codable, Sendable {
    public let headerArtworkURL: URL?
    public let monthlyListeners: Int?
    public let isVerified: Bool
    public let popularTracks: [CatalogArtistPopularTrack]
    public let popularReleases: [CatalogItem]
    public let featuringPlaylists: [CatalogItem]?
    public let biography: String?
    public let aboutArtworkURL: URL?
    public let followers: Int?
    public let discoveredOnPlaylists: [CatalogItem]?
    public let artistPlaylists: [CatalogItem]?

    public init(
        headerArtworkURL: URL? = nil, monthlyListeners: Int? = nil, isVerified: Bool = false,
        popularTracks: [CatalogArtistPopularTrack] = [], popularReleases: [CatalogItem] = [],
        featuringPlaylists: [CatalogItem]? = nil,
        biography: String? = nil, aboutArtworkURL: URL? = nil, followers: Int? = nil,
        discoveredOnPlaylists: [CatalogItem]? = nil, artistPlaylists: [CatalogItem]? = nil
    ) {
        self.headerArtworkURL = headerArtworkURL
        self.monthlyListeners = monthlyListeners
        self.isVerified = isVerified
        self.popularTracks = popularTracks
        self.popularReleases = popularReleases
        self.featuringPlaylists = featuringPlaylists
        self.biography = biography
        self.aboutArtworkURL = aboutArtworkURL
        self.followers = followers
        self.discoveredOnPlaylists = discoveredOnPlaylists
        self.artistPlaylists = artistPlaylists
    }
}
