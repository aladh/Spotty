import Foundation

public enum PlaybackEventSource: Hashable, Sendable {
    case account
    case engineConnection
    case enginePlayback
    case engineQueue
    case engineDevices
    case engineCluster
    case command
    case metadata
    case user
}

public struct PlaybackEventEnvelope: Sendable {
    public let accountEpoch: UInt64
    public let engineEpoch: UInt64
    public let source: PlaybackEventSource
    public let revision: UInt64?
    public let receivedAt: Date
    public let event: PlaybackEvent

    public init(
        accountEpoch: UInt64,
        engineEpoch: UInt64,
        source: PlaybackEventSource,
        revision: UInt64? = nil,
        receivedAt: Date = Date(),
        event: PlaybackEvent
    ) {
        self.accountEpoch = accountEpoch
        self.engineEpoch = engineEpoch
        self.source = source
        self.revision = revision
        self.receivedAt = receivedAt
        self.event = event
    }
}

public enum PlaybackEvent: Sendable {
    case reset(session: PlaybackSessionPhase)
    case session(PlaybackSessionPhase)
    case owner(PlaybackOwner)
    case enginePlayback(EnginePlaybackSnapshot)
    case engineConnection(EngineConnectionSnapshot)
    case engineCluster(EngineConnectSnapshot)
    case presentation(PlaybackPresentationSnapshot)
    case trackMetadata(PlaybackTrackMetadata)
    case timing(position: TimeInterval, duration: TimeInterval, anchoredAt: Date)
    case options(PlaybackOptions)
    case queue(PlaybackQueueSnapshot)
    case devices(PlaybackDeviceSnapshot)
    case commandStarted(PendingPlaybackCommand)
    case commandFinished(id: UUID, accepted: Bool, notice: PlaybackNotice?)
    case notice(PlaybackNotice?)
}
