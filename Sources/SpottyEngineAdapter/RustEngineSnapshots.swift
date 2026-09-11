import Foundation
import SpottyDomain

/// Engine playback observation. Transport, empty-URI identity, and option values
/// are projected at intake (`PlaybackSnapshotProjection`).
public nonisolated struct RustPlaybackState: Sendable {
    public let revision: UInt64
    public let sessionGeneration: UInt64
    public let isPlaying: Bool
    public let isPaused: Bool
    public let trackURI: String
    public let contextURI: String?
    public let positionMS: Int64
    public let durationMS: Int64
    public let timestampMS: Int64
    public let shuffle: Bool
    public let repeatTrack: Bool
    public let repeatContext: Bool
    /// One-shot local current-request failure from the retained engine. Synthetic callers that
    /// predate the wire field receive the safe default.
    public let trackUnavailable: Bool
    public let audioKeyRefused: Bool
    /// Active-member fact captured with the same Connect player observation.
    /// The initializer defaults this for synthetic callers that predate the wire field.
    public let isActiveDevice: Bool

    public init(
        revision: UInt64,
        sessionGeneration: UInt64,
        isPlaying: Bool,
        isPaused: Bool,
        trackURI: String,
        positionMS: Int64,
        durationMS: Int64,
        timestampMS: Int64,
        shuffle: Bool,
        repeatTrack: Bool,
        repeatContext: Bool,
        trackUnavailable: Bool = false,
        audioKeyRefused: Bool = false,
        isActiveDevice: Bool = false,
        contextURI: String? = nil
    ) {
        self.revision = revision
        self.sessionGeneration = sessionGeneration
        self.isPlaying = isPlaying
        self.isPaused = isPaused
        self.trackURI = trackURI
        self.contextURI = contextURI
        self.positionMS = positionMS
        self.durationMS = durationMS
        self.timestampMS = timestampMS
        self.shuffle = shuffle
        self.repeatTrack = repeatTrack
        self.repeatContext = repeatContext
        self.trackUnavailable = trackUnavailable
        self.audioKeyRefused = audioKeyRefused
        self.isActiveDevice = isActiveDevice
    }
}

public nonisolated struct RustQueueState: Sendable {
    /// Current-track identity from the engine. Catalog enrichment supplies names.
    public struct Item: Sendable {
        public let uri: String
        public let provider: String
        public let uid: String

        public init(uri: String, provider: String, uid: String) {
            self.uri = uri
            self.provider = provider
            self.uid = uid
        }
    }

    public let revision: UInt64
    public let sessionGeneration: UInt64
    public let track: Item?
    public let protocolNextTracks: [QueueProtocolTrack]
    public let protocolPrevTracks: [QueueProtocolTrack]
    public let queueRevision: String
    public let disallowSetQueue: Bool
    public let disallowRemovingFromNextTracks: Bool

    public init(
        revision: UInt64,
        sessionGeneration: UInt64,
        track: Item?,
        protocolNextTracks: [QueueProtocolTrack],
        protocolPrevTracks: [QueueProtocolTrack],
        queueRevision: String,
        disallowSetQueue: Bool,
        disallowRemovingFromNextTracks: Bool
    ) {
        self.revision = revision
        self.sessionGeneration = sessionGeneration
        self.track = track
        self.protocolNextTracks = protocolNextTracks
        self.protocolPrevTracks = protocolPrevTracks
        self.queueRevision = queueRevision
        self.disallowSetQueue = disallowSetQueue
        self.disallowRemovingFromNextTracks = disallowRemovingFromNextTracks
    }
}

public nonisolated struct RustConnectionState: Sendable {
    public let revision: UInt64
    public let sessionGeneration: UInt64
    public let sessionConnected: Bool
    public let spircReady: Bool
    public let isActiveDevice: Bool
    /// Engine reconnect is holding readiness open for Swift's resume-load targets.
    public let resumePending: Bool
    public let lastError: String?
    public let deviceID: String?
    /// Definitive streaming-credential rejection, distinct from generic reconnect failure.
    /// The initializer defaults this for synthetic callers that predate the wire field.
    public let credentialsRejected: Bool

    public init(
        revision: UInt64,
        sessionGeneration: UInt64,
        sessionConnected: Bool,
        spircReady: Bool,
        isActiveDevice: Bool,
        resumePending: Bool,
        lastError: String?,
        deviceID: String?,
        credentialsRejected: Bool = false
    ) {
        self.revision = revision
        self.sessionGeneration = sessionGeneration
        self.sessionConnected = sessionConnected
        self.spircReady = spircReady
        self.isActiveDevice = isActiveDevice
        self.resumePending = resumePending
        self.lastError = lastError
        self.deviceID = deviceID
        self.credentialsRejected = credentialsRejected
    }
}

public nonisolated struct RustDevicesState: Sendable {
    public let revision: UInt64
    public let sessionGeneration: UInt64
    public let activeDeviceID: String
    public let devices: [ConnectProtocolDevice]

    public init(
        revision: UInt64,
        sessionGeneration: UInt64,
        activeDeviceID: String,
        devices: [ConnectProtocolDevice]
    ) {
        self.revision = revision
        self.sessionGeneration = sessionGeneration
        self.activeDeviceID = activeDeviceID
        self.devices = devices
    }
}
