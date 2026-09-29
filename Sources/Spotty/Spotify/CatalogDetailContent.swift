import Foundation
import SpottyDomain
import SpottyRuntimeContracts

/// Content has one representation whether it is visible or retained. Session and freshness
/// evidence belong to the detail lifecycle, not to these display values.
struct PlaylistDetailContent {
    var item: CatalogItem?
    var collection: CatalogTrackCollection
    var totalDuration: TimeInterval = 0
    var description = ""
    var ownerURI: String?

    init(item: CatalogItem? = nil) {
        self.item = item
        collection = CatalogTrackCollection()
    }

    init(_ result: CatalogPlaylistSnapshot, selected: CatalogItem) {
        item = result.item?.uri == selected.uri ? (result.item ?? selected) : selected
        collection = CatalogTrackCollection(tracks: result.tracks)
        totalDuration = Self.duration(of: collection)
        description = result.description
        ownerURI = result.freshness.isCurrent ? result.ownerURI : nil
    }

    static func duration(of collection: CatalogTrackCollection) -> TimeInterval {
        collection.tracks.reduce(0) { $0 + TimeInterval(roundedCatalogDurationSeconds($1.duration)) }
    }
}

struct AlbumDetailContent {
    var item: CatalogItem?
    var collection: CatalogTrackCollection
    var releaseDate = ""
    var playCounts: [String: Int64] = [:]
    var artists: [CatalogItem] = []

    init(item: CatalogItem? = nil) {
        self.item = item
        collection = CatalogTrackCollection()
    }

    init(_ result: CatalogAlbumSnapshot, selected: CatalogItem) {
        item = result.item?.uri == selected.uri ? (result.item ?? selected) : selected
        collection = CatalogTrackCollection(tracks: result.tracks)
        releaseDate = result.releaseDate
        playCounts = result.playCounts ?? [:]
        artists = result.artists ?? []
    }
}

struct ArtistDetailContent {
    var item: CatalogItem?
    var releases: [CatalogItem] = []
    var overview: CatalogArtistOverview?
    var releaseKinds: [String: CatalogArtistReleaseKind] = [:]
    var releaseDates: [String: String] = [:]
    var popularTracks: CatalogTrackCollection
    var popularPreview: CatalogTrackCollection
    var artistTracks: [String: CatalogArtistPopularTrack] = [:]

    init(item: CatalogItem? = nil) {
        self.item = item
        popularTracks = CatalogTrackCollection()
        popularPreview = CatalogTrackCollection()
    }

    init(_ result: CatalogArtistSnapshot, selected: CatalogItem) {
        item = result.item?.uri == selected.uri && result.name != nil ? (result.item ?? selected) : selected
        releases = result.releases.map { release in
            guard release.subtitle.isEmpty else { return release }
            return CatalogItem(
                id: release.id, uri: release.uri, title: release.title,
                subtitle: result.name ?? selected.title, artworkURL: release.artworkURL,
                kind: release.kind, ownerURI: release.ownerURI)
        }
        overview = result.overview
        releaseKinds = result.releaseKinds ?? [:]
        releaseDates = result.releaseDates ?? [:]
        popularTracks = CatalogTrackCollection(tracks: overview?.popularTracks.map(\.track) ?? [])
        popularPreview = CatalogTrackCollection(tracks: Array(popularTracks.tracks.prefix(5)))
        artistTracks = Dictionary(
            (overview?.popularTracks ?? []).map { ($0.track.uri, $0) },
            uniquingKeysWith: { first, _ in first })
    }
}

/// A closed set of detail kinds keeps provider mapping and lifecycle policy together. This is
/// an implementation value, not a recipe that asks feature callers to assemble a load protocol.
enum CatalogDetailKind {
    case playlist, album, artistOverview, artistDiscography

    var itemKind: CatalogItem.Kind {
        switch self {
        case .playlist: .playlist
        case .album: .album
        case .artistOverview, .artistDiscography: .artist
        }
    }

    var uriKind: String {
        switch self {
        case .playlist: "playlist"
        case .album: "album"
        case .artistOverview, .artistDiscography: "artist"
        }
    }

    func emptyContent(item: CatalogItem? = nil) -> CatalogDetailPayload {
        switch self {
        case .playlist: .playlist(PlaylistDetailContent(item: item))
        case .album: .album(AlbumDetailContent(item: item))
        case .artistOverview, .artistDiscography: .artist(ArtistDetailContent(item: item))
        }
    }
}

enum CatalogDetailPayload {
    case playlist(PlaylistDetailContent)
    case album(AlbumDetailContent)
    case artist(ArtistDetailContent)

    var item: CatalogItem? {
        switch self {
        case let .playlist(value): value.item
        case let .album(value): value.item
        case let .artist(value): value.item
        }
    }

    /// Only playlist and album collections currently participate in entity subscriptions.
    var observedCollection: CatalogTrackCollection? {
        switch self {
        case let .playlist(value): value.collection
        case let .album(value): value.collection
        case .artist: nil
        }
    }

    var retentionCost: Int {
        switch self {
        case let .playlist(value): value.collection.tracks.count
        case let .album(value): value.collection.tracks.count
        case let .artist(value): value.releases.count + value.popularTracks.tracks.count
        }
    }

    func replacingCollection(_ collection: CatalogTrackCollection) -> Self {
        switch self {
        case var .playlist(value):
            value.collection = collection
            value.totalDuration = PlaylistDetailContent.duration(of: collection)
            return .playlist(value)
        case var .album(value):
            value.collection = collection
            return .album(value)
        case .artist: return self
        }
    }
}
