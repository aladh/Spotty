import Foundation
import SpottyDomain

// Explicit projections persist only documented catalog fields, never transport payloads or grants.
struct StoredItem: Codable, Equatable {
    let id: String
    let uri: String
    let title: String
    let subtitle: String
    let artworkURL: URL?
    let kind: String
    let ownerURI: String?

    init(_ item: CatalogItem) {
        id = item.id
        uri = item.uri
        title = item.title
        subtitle = item.subtitle
        artworkURL = item.artworkURL
        kind = item.kind.rawValue
        ownerURI = item.ownerURI
    }

    var value: CatalogItem {
        CatalogItem(
            id: id, uri: uri, title: title, subtitle: subtitle, artworkURL: artworkURL,
            kind: CatalogItem.Kind(rawValue: kind) ?? .unknown, ownerURI: ownerURI
        )
    }
}

struct StoredTrack: Codable, Equatable {
    let uri: String
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let artworkURL: URL?
    let artists: [StoredItem]
    let albumItem: StoredItem?

    init(_ track: CatalogTrack) {
        uri = track.uri
        title = track.title
        artist = track.artist
        album = track.album
        duration = track.duration
        artworkURL = track.artworkURL
        artists = track.artists.map(StoredItem.init)
        albumItem = track.albumItem.map(StoredItem.init)
    }

    func value(id: String, addedAt: Date? = nil, occurrenceUID: String? = nil) -> CatalogTrack {
        CatalogTrack(
            id: id, uri: uri, title: title, artist: artist, album: album, duration: duration,
            artworkURL: artworkURL, addedAt: addedAt, artists: artists.map(\.value), albumItem: albumItem?.value,
            occurrenceUID: occurrenceUID
        )
    }
}

struct StoredOccurrence: Codable, Equatable {
    let id: String
    let requestedURI: String
    let serverUID: String?
    let trackID: String
    let addedAt: Date?

    init(_ occurrence: CatalogOccurrence) {
        id = occurrence.id
        requestedURI = occurrence.requestedURI
        serverUID = occurrence.serverUID
        trackID = occurrence.track.id
        addedAt = occurrence.track.addedAt
    }
}

struct StoredCollection: Codable, Equatable {
    let completeness: CatalogCollectionCompleteness
    let revision: String?
    let fetchedAt: Date
    let item: StoredItem?
    let description: String
    let ownerURI: String?
    let releaseDate: String

    init(_ write: CatalogCollectionWrite) {
        completeness = write.completeness
        revision = write.revision
        fetchedAt = write.fetchedAt
        item = write.metadata.item.map(StoredItem.init)
        description = write.metadata.description
        ownerURI = write.metadata.ownerURI
        releaseDate = write.metadata.releaseDate
    }

    var metadata: CatalogCollectionMetadata {
        CatalogCollectionMetadata(
            item: item?.value, description: description, ownerURI: ownerURI, releaseDate: releaseDate)
    }
}
