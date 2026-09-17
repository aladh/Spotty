import Foundation

/// Shared track metadata projected to a requested URI. Collection row identity, occurrence
/// authority and date added cannot travel through this value.
public struct CatalogTrackMetadata: Codable, Equatable, Sendable {
    public let uri: String
    public let title: String
    public let artist: String
    public let album: String
    public let duration: TimeInterval
    public let artworkURL: URL?
    public let artists: [CatalogItem]
    public let albumItem: CatalogItem?

    /// Storage may return relinked playback metadata under the original requested URI.
    public init(track: CatalogTrack, requestedURI: String) {
        uri = requestedURI
        title = track.title
        artist = track.artist
        album = track.album
        duration = track.duration
        artworkURL = track.artworkURL
        artists = track.artists
        albumItem = track.albumItem
    }
}

extension CatalogTrack {
    /// Missing destinations mean unknown, not a request to erase a link already learned for
    /// this track. Changed artist/album labels prevent borrowing a conflicting destination.
    public func fillingMissingLinks(from known: CatalogTrack?) -> CatalogTrack {
        guard let known, known.uri == uri else { return self }
        let resolvedArtists = artists.isEmpty && !artist.isEmpty && artist == known.artist ? known.artists : artists
        let resolvedAlbum =
            albumItem == nil && !album.isEmpty && album == known.album && artist == known.artist
            ? known.albumItem : albumItem
        guard resolvedArtists != artists || resolvedAlbum != albumItem else { return self }
        return CatalogTrack(
            id: id, uri: uri, title: title, artist: artist, album: album, duration: duration,
            artworkURL: artworkURL, addedAt: addedAt, artists: resolvedArtists, albumItem: resolvedAlbum,
            occurrenceUID: occurrenceUID)
    }
}
