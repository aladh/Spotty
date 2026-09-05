//
//  CatalogModels.swift
//  Spotty
//

import Foundation

/// One playable row in a track list.
public struct CatalogTrack: Identifiable, Equatable, Sendable {
    public let id: String
    public let uri: String
    public let title: String
    public let artist: String
    public let album: String
    public let duration: TimeInterval
    public let artworkURL: URL?
    public let addedAt: Date?
    public let artists: [CatalogItem]
    public let albumItem: CatalogItem?

    public init(
        id: String,
        uri: String,
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        artworkURL: URL?,
        addedAt: Date?,
        artists: [CatalogItem] = [],
        albumItem: CatalogItem? = nil
    ) {
        self.id = id
        self.uri = uri
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.artworkURL = artworkURL
        self.addedAt = addedAt
        self.artists = artists
        self.albumItem = albumItem
    }

    /// A nonoptional key gives SwiftUI's native Table header a sortable date column.
    public var dateAddedSortValue: Date { addedAt ?? .distantPast }
}

/// One card in the home shelves or a library grid.
public struct CatalogItem: Identifiable, Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case album = "Album"
        case artist = "Artist"
        case playlist = "Playlist"
        case track = "Track"
        case unknown = "Spotify"
    }

    public let id: String
    public let uri: String
    public let title: String
    public let subtitle: String
    public let artworkURL: URL?
    public let kind: Kind
    /// Playlist owner `spotify:user:` URI when known. Absent for non-playlists and for
    /// restored stubs that have not loaded ownership metadata yet.
    public let ownerURI: String?

    public init(
        id: String,
        uri: String,
        title: String,
        subtitle: String,
        artworkURL: URL?,
        kind: Kind,
        ownerURI: String? = nil
    ) {
        self.id = id
        self.uri = uri
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.kind = kind
        self.ownerURI = ownerURI
    }
}

/// One shelf on the home page.
public struct CatalogSection: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let items: [CatalogItem]

    public init(id: String, title: String, items: [CatalogItem]) {
        self.id = id
        self.title = title
        self.items = items
    }
}
