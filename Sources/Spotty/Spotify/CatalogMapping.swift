//
//  CatalogMapping.swift
//  Spotty
//
//  Pure conversion from Spotify transport models to Spotty catalog models.
//

import SpottyDomain
import Foundation

nonisolated enum CatalogMapping {
    private static let standardISODate = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
    private static let fractionalISODate = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    static func searchTrack(from track: PathfinderTrack) -> CatalogTrack? {
        guard let uri = track.uri, !uri.isEmpty else { return nil }
        return CatalogTrack(
            id: uri,
            uri: uri,
            title: track.name ?? "Unknown Track",
            artist: track.artistNames.joined(separator: ", "),
            album: track.albumOfTrack?.name ?? "",
            duration: TimeInterval(track.durationMs ?? 0) / 1_000,
            artworkURL: track.albumOfTrack?.coverArt?.largestURL.flatMap(URL.init(string:)),
            addedAt: nil,
            artists: artistItems(track.artists),
            albumItem: albumItem(uri: track.albumOfTrack?.uri, name: track.albumOfTrack?.name)
        )
    }

    static func sections(from home: PathfinderHome) -> [CatalogSection] {
        home.sections.enumerated().compactMap { index, section in
            let items = section.items.flatMap { entry -> [CatalogItem] in
                guard let content = entry.content else { return [] }
                switch content {
                case let .album(album):
                    return item(from: album).map { [$0] } ?? []
                case let .artist(artist):
                    return item(from: artist).map { [$0] } ?? []
                case let .playlist(playlist):
                    return item(from: playlist).map { [$0] } ?? []
                case let .list(list):
                    return list.entities.compactMap(item(from:))
                case .unsupported:
                    return []
                }
            }
            guard !items.isEmpty else { return nil }
            return CatalogSection(
                id: section.uri ?? "home-section-\(index)",
                title: section.title ?? "Recently played",
                items: items
            )
        }
    }

    static func item(from album: PathfinderAlbum) -> CatalogItem? {
        guard let uri = album.uri, !uri.isEmpty else { return nil }
        return CatalogItem(
            id: uri,
            uri: uri,
            title: album.name ?? "Untitled album",
            subtitle: album.artistNames.joined(separator: ", "),
            artworkURL: album.coverArt?.largestURL.flatMap(URL.init(string:)),
            kind: .album
        )
    }

    static func item(from artist: PathfinderArtist) -> CatalogItem? {
        guard let uri = artist.uri, !uri.isEmpty else { return nil }
        return CatalogItem(
            id: uri,
            uri: uri,
            title: artist.name ?? "Unknown artist",
            subtitle: "Artist",
            artworkURL: artist.imageURL.flatMap(URL.init(string:)),
            kind: .artist
        )
    }

    static func item(from playlist: PathfinderPlaylist) -> CatalogItem? {
        guard playlist.id != nil, let uri = playlist.uri, SpotifyURI.id(from: uri, kind: "playlist") != nil else {
            return nil
        }
        return CatalogItem(
            id: uri,
            uri: uri,
            title: playlist.name ?? "Untitled playlist",
            subtitle: playlist.ownerName ?? "Playlist",
            artworkURL: playlist.imageURL.flatMap(URL.init(string:)),
            kind: .playlist,
            ownerURI: ownerURI(from: playlist.ownerV2?.data?.uri, username: playlist.ownerV2?.data?.username)
        )
    }

    static func item(from entity: PathfinderHomeEntity) -> CatalogItem? {
        guard let uri = entity.uri, !uri.isEmpty else { return nil }
        let kind: CatalogItem.Kind
        switch uri.split(separator: ":").dropFirst().first {
        case "album": kind = .album
        case "artist": kind = .artist
        case "playlist": kind = .playlist
        case "track": kind = .track
        default: kind = .unknown
        }
        return CatalogItem(
            id: uri,
            uri: uri,
            title: entity.name ?? "Spotify item",
            subtitle: entity.firstContributor?.name ?? kind.rawValue,
            artworkURL: entity.imageSources.max { ($0.width ?? 0) < ($1.width ?? 0) }?.url.flatMap(URL.init(string:)),
            kind: kind
        )
    }

    static func item(from release: PathfinderRelease, artist: String) -> CatalogItem? {
        guard let uri = release.uri, !uri.isEmpty else { return nil }
        return CatalogItem(
            id: uri,
            uri: uri,
            title: release.name ?? "Untitled release",
            subtitle: artist,
            artworkURL: release.coverArt?.largestURL.flatMap(URL.init(string:)),
            kind: .album
        )
    }

    static func albumTrack(
        from track: PathfinderAlbumTrack,
        album: PathfinderAlbumUnion
    ) -> CatalogTrack? {
        guard let uri = track.uri, !uri.isEmpty else { return nil }
        return CatalogTrack(
            id: uri,
            uri: uri,
            title: track.name ?? "Unknown Track",
            artist: track.artistNames.joined(separator: ", "),
            album: album.name ?? "",
            duration: TimeInterval(track.duration?.totalMilliseconds ?? 0) / 1_000,
            artworkURL: album.coverArt?.largestURL.flatMap(URL.init(string:)),
            addedAt: nil,
            artists: artistItems(track.artists),
            albumItem: albumItem(uri: album.uri, name: album.name)
        )
    }

    static func track(from item: PathfinderLibraryTrackItem) -> CatalogTrack? {
        guard let uri = item.track?.uri, let track = item.track?.data, !uri.isEmpty else { return nil }
        return CatalogTrack(
            id: uri,
            uri: uri,
            title: track.name ?? "Unknown Track",
            artist: track.artistNames.joined(separator: ", "),
            album: track.albumOfTrack?.name ?? "",
            duration: TimeInterval(track.durationMs ?? 0) / 1_000,
            artworkURL: track.albumOfTrack?.coverArt?.largestURL.flatMap(URL.init(string:)),
            addedAt: nil,
            artists: artistItems(track.artists),
            albumItem: albumItem(uri: track.albumOfTrack?.uri, name: track.albumOfTrack?.name)
        )
    }

    static func playlistTrack(from entry: PathfinderPlaylistItem) -> CatalogTrack? {
        guard let track = entry.track, let uri = track.uri, !uri.isEmpty else { return nil }
        return CatalogTrack(
            id: entry.uid ?? uri,
            uri: uri,
            title: track.name ?? "Unknown Track",
            artist: track.artistNames.joined(separator: ", "),
            album: track.albumOfTrack?.name ?? "",
            duration: TimeInterval(track.trackDuration?.totalMilliseconds ?? 0) / 1_000,
            artworkURL: track.albumOfTrack?.coverArt?.largestURL.flatMap(URL.init(string:)),
            addedAt: spotifyDate(from: entry.addedAt?.isoString),
            artists: artistItems(track.artists),
            albumItem: albumItem(uri: track.albumOfTrack?.uri, name: track.albumOfTrack?.name)
        )
    }

    private static func artistItems(_ artists: PathfinderArtistList?) -> [CatalogItem] {
        let entries = artists?.items ?? []
        let mapped: [CatalogItem] = entries.compactMap { artist in
            guard let uri = artist.uri, SpotifyURI.id(from: uri, kind: "artist") != nil,
                let name = artist.name
            else { return nil }
            return CatalogItem(id: uri, uri: uri, title: name, subtitle: "Artist", artworkURL: nil, kind: .artist)
        }
        return mapped.count == entries.count ? mapped : []
    }

    private static func albumItem(uri: String?, name: String?) -> CatalogItem? {
        guard let uri, SpotifyURI.id(from: uri, kind: "album") != nil, let name else { return nil }
        return CatalogItem(id: uri, uri: uri, title: name, subtitle: "Album", artworkURL: nil, kind: .album)
    }

    static func profileUserURI(from profile: PathfinderProfile) -> String? {
        ownerURI(from: profile.uri, username: profile.username)
    }

    static func ownerURI(from playlist: PathfinderPlaylistUnion) -> String? {
        ownerURI(from: playlist.ownerV2?.data?.uri, username: playlist.ownerV2?.data?.username)
    }

    static func ownerURI(from uri: String?, username: String?) -> String? {
        PlaylistEditability.userURI(uri: uri, username: username)
    }

    static func spotifyDate(from value: String?) -> Date? {
        guard let value else { return nil }
        guard let date = (try? standardISODate.parse(value)) ?? (try? fractionalISODate.parse(value)) else {
            return nil
        }
        // Spotify uses the Unix epoch as an "unknown" sentinel on generated/public playlist
        // entries. Showing that value in Toronto renders as Dec 31, 1969, which is misleading;
        // Spotify did not exist at the epoch, so it can never be a legitimate added date.
        return date.timeIntervalSince1970 > 0 ? date : nil
    }
}
