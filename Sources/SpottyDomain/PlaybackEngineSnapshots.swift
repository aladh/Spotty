import Foundation

/// One authoritative engine playback sample. Keeping its transport, identity, timing, and
/// options together prevents the UI from observing combinations that never existed upstream.
public struct EnginePlaybackSnapshot: Equatable, Sendable {
    public let transport: PlaybackTransportState
    public let trackURI: String?
    /// Nil means this sample does not carry context; an empty string clears it.
    public let contextURI: String?
    public let timing: PlaybackTiming
    /// True for the one-shot local playback sample that reports the current requested track could
    /// not be played. The intake projection filters this to an active device and non-empty URI.
    public let trackUnavailable: Bool
    public let shuffle: Bool?
    public let repeatMode: RepeatMode?
    public let repeatFlags: RepeatFlags?

    public init(
        transport: PlaybackTransportState,
        trackURI: String?,
        timing: PlaybackTiming,
        trackUnavailable: Bool = false,
        shuffle: Bool? = nil,
        repeatMode: RepeatMode? = nil,
        repeatFlags: RepeatFlags? = nil,
        contextURI: String? = nil
    ) {
        self.transport = transport
        self.trackURI = trackURI
        self.contextURI = contextURI
        self.timing = timing
        self.trackUnavailable = trackUnavailable
        self.shuffle = shuffle
        self.repeatMode = repeatMode
        self.repeatFlags = repeatFlags
    }
}

/// One connection callback reduced atomically with the device identity it describes.
public struct EngineConnectionSnapshot: Equatable, Sendable {
    public let session: PlaybackSessionPhase?
    public let owner: PlaybackOwner
    public let localDeviceID: String?

    public init(
        session: PlaybackSessionPhase?,
        owner: PlaybackOwner,
        localDeviceID: String?
    ) {
        self.session = session
        self.owner = owner
        self.localDeviceID = localDeviceID
    }
}
