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
