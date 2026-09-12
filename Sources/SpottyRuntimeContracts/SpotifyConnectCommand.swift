import Foundation
import SpottyDomain

/// Semantic remote playback intent. HTTP names, JSON keys, and logging identifiers belong to the gateway.
public struct SpotifyConnectCommand: Sendable {
    public enum Kind: String, Sendable {
        case pause, resume, next, previous, seek, shuffle, repeatContext, repeatTrack, addToQueue, setQueue, play
    }
    public enum Value: Sendable {
        case integer(Int)
        case boolean(Bool)
    }
    public struct Context: Sendable {
        public let uri: String
        public let trackIndex: Int?
        public let trackURIs: [String]?
    }
    public struct Track: Sendable { public let uri: String }

    public let endpoint: Kind
    public var value: Value?
    public var context: Context?
    public var track: Track?
    public var nextTracks: [QueueProtocolTrack]?
    public var prevTracks: [QueueProtocolTrack]?
    public var queueRevision: String?

    public static let pause = Self(endpoint: .pause)
    public static let resume = Self(endpoint: .resume)
    public static let next = Self(endpoint: .next)
    public static let previous = Self(endpoint: .previous)
    public static func seek(to milliseconds: Int) -> Self {
        Self(endpoint: .seek, value: .integer(max(0, milliseconds)))
    }
    public static func shuffle(_ enabled: Bool) -> Self { Self(endpoint: .shuffle, value: .boolean(enabled)) }
    public static func repeatContext(_ enabled: Bool) -> Self {
        Self(endpoint: .repeatContext, value: .boolean(enabled))
    }
    public static func repeatTrack(_ enabled: Bool) -> Self { Self(endpoint: .repeatTrack, value: .boolean(enabled)) }
    public static func repeatMutation(_ mutation: RepeatFlagMutation) -> Self {
        switch mutation.flag {
        case .context: repeatContext(mutation.enabled)
        case .track: repeatTrack(mutation.enabled)
        }
    }
    public static func addToQueue(_ uri: String) -> Self { Self(endpoint: .addToQueue, track: Track(uri: uri)) }
    public static func setQueue(next: [QueueProtocolTrack], prev: [QueueProtocolTrack], queueRevision: String) -> Self {
        Self(endpoint: .setQueue, nextTracks: next, prevTracks: prev, queueRevision: queueRevision)
    }
    public static func play(uri: String, trackIndex: Int? = nil) -> Self {
        Self(endpoint: .play, context: Context(uri: uri, trackIndex: trackIndex, trackURIs: nil))
    }
    public static func play(trackURIs: [String]) -> Self {
        Self(endpoint: .play, context: Context(uri: "", trackIndex: nil, trackURIs: trackURIs))
    }
}

public struct SpotifyConnectTrackMetadata: Sendable {
    public let uri: String
    public let title: String
    public let artist: String
    public let artworkURL: URL?
    public let duration: TimeInterval
    public var artists: [CatalogItem]

    public init(
        uri: String, title: String, artist: String, artworkURL: URL?, duration: TimeInterval,
        artists: [CatalogItem] = []
    ) {
        self.uri = uri
        self.title = title
        self.artist = artist
        self.artworkURL = artworkURL
        self.duration = duration
        self.artists = artists
    }
}

public protocol RemotePlaybackClient: Sendable {
    func send(_ command: SpotifyConnectCommand, from sourceID: String, to targetID: String) async throws
    func trackMetadata(for uri: String) async throws -> SpotifyConnectTrackMetadata
}

public protocol WebQueueClient: Sendable {
    func queue() async throws -> [CatalogTrack]
}
