import Foundation

/// A cached queue snapshot may enrich the current track, but it never owns playback identity.
/// Returning nil for a mismatch prevents a pre-reconnect queue cache from replacing a newer
/// playback callback's track.
public func queueBootstrapMetadataURI(
    snapshotTrackURI: String?,
    currentTrackURI: String?
) -> String? {
    guard let snapshotTrackURI, !snapshotTrackURI.isEmpty,
        snapshotTrackURI == currentTrackURI
    else { return nil }
    return snapshotTrackURI
}

public enum PlaybackTransportState: Equatable, Sendable, Codable {
    case stopped
    case buffering
    case paused
    case playing
}

public enum MetadataProvenance: Int, Comparable, Sendable, Codable {
    case none = 0
    case catalog = 1
    case connect = 2
    case engine = 3

    public static func < (lhs: MetadataProvenance, rhs: MetadataProvenance) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct CurrentTrack: Equatable, Sendable, Codable {
    public var uri: String
    public var title: String?
    public var artist: String?
    public var artworkURL: URL?
    public var duration: TimeInterval
    public var metadataSource: MetadataProvenance

    public init(
        uri: String,
        title: String? = nil,
        artist: String? = nil,
        artworkURL: URL? = nil,
        duration: TimeInterval = 0,
        metadataSource: MetadataProvenance = .none
    ) {
        self.uri = uri
        self.title = title
        self.artist = artist
        self.artworkURL = artworkURL
        self.duration = duration
        self.metadataSource = metadataSource
    }
}

public struct PlaybackTiming: Equatable, Sendable, Codable {
    public var position: TimeInterval
    public var duration: TimeInterval
    public var anchoredAt: Date

    public init(position: TimeInterval = 0, duration: TimeInterval = 0, anchoredAt: Date = Date()) {
        self.position = position
        self.duration = duration
        self.anchoredAt = anchoredAt
    }
}

/// A complete user-visible playback presentation. Optimistic starts, rollbacks, and restoration
/// enter the reducer as one value so observers never see a title from one track paired with the
/// transport or timing of another.
public struct PlaybackPresentationSnapshot: Equatable, Sendable, Codable {
    public var currentTrack: CurrentTrack?
    public var transport: PlaybackTransportState
    public var timing: PlaybackTiming

    public init(
        currentTrack: CurrentTrack?,
        transport: PlaybackTransportState,
        timing: PlaybackTiming
    ) {
        self.currentTrack = currentTrack
        self.transport = currentTrack == nil ? .stopped : transport
        self.timing = currentTrack == nil ? PlaybackTiming(anchoredAt: timing.anchoredAt) : timing
    }
}

/// Metadata enrichment is scoped to a URI and replaces all display fields atomically. A stale
/// response for a track that is no longer current is rejected by the reducer.
public struct PlaybackTrackMetadata: Equatable, Sendable {
    public let uri: String
    public let title: String?
    public let artist: String?
    public let artworkURL: URL?
    public let duration: TimeInterval
    public let source: MetadataProvenance

    public init(
        uri: String,
        title: String?,
        artist: String?,
        artworkURL: URL?,
        duration: TimeInterval,
        source: MetadataProvenance
    ) {
        self.uri = uri
        self.title = title
        self.artist = artist
        self.artworkURL = artworkURL
        self.duration = max(0, duration)
        self.source = source
    }
}

public struct PlaybackOptions: Equatable, Sendable, Codable {
    public var shuffle: Bool
    public var repeatMode: RepeatMode
    /// Independent Connect/FFI switches. `repeatMode` is the display collapse
    /// (`track` wins when both are true); planning uses this pair so a live
    /// both-true snapshot is not forgotten as `context: false`.
    public var repeatFlags: RepeatFlags

    public init(
        shuffle: Bool = false,
        repeatMode: RepeatMode = .off,
        repeatFlags: RepeatFlags? = nil
    ) {
        self.shuffle = shuffle
        self.repeatMode = repeatMode
        self.repeatFlags = repeatFlags ?? repeatMode.flags
    }
}
