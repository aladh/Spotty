import Foundation
public struct PlaybackState: Equatable, Sendable {
    public var accountEpoch: UInt64
    public var engineEpoch: UInt64
    public var session: PlaybackSessionPhase
    public var owner: PlaybackOwner
    public var transport: PlaybackTransportState
    public var currentTrack: CurrentTrack?
    public internal(set) var playbackContextURI: String?
    public var timing: PlaybackTiming
    public var options: PlaybackOptions
    public var queue: PlaybackQueueSnapshot
    public var devices: PlaybackDeviceSnapshot
    public var pendingCommands: [PlaybackCommandKind: PendingPlaybackCommand]
    public var notice: PlaybackNotice?
    public var sourceRevisions: [PlaybackEventSource: UInt64]
    public var transportCommandResolutions: [UUID: PlaybackTransportCommandResolution]

    public init(
        accountEpoch: UInt64 = 0,
        engineEpoch: UInt64 = 0,
        session: PlaybackSessionPhase = .signedOut,
        owner: PlaybackOwner = .none,
        transport: PlaybackTransportState = .stopped,
        currentTrack: CurrentTrack? = nil,
        playbackContextURI: String? = nil,
        timing: PlaybackTiming = PlaybackTiming(),
        options: PlaybackOptions = PlaybackOptions(),
        queue: PlaybackQueueSnapshot = PlaybackQueueSnapshot(),
        devices: PlaybackDeviceSnapshot = PlaybackDeviceSnapshot(),
        pendingCommands: [PlaybackCommandKind: PendingPlaybackCommand] = [:],
        notice: PlaybackNotice? = nil,
        sourceRevisions: [PlaybackEventSource: UInt64] = [:],
        transportCommandResolutions: [UUID: PlaybackTransportCommandResolution] = [:]
    ) {
        self.accountEpoch = accountEpoch
        self.engineEpoch = engineEpoch
        self.session = session
        self.owner = owner
        self.transport = transport
        self.currentTrack = currentTrack
        self.playbackContextURI = playbackContextURI
        self.timing = timing
        self.options = options
        self.queue = queue
        self.devices = devices
        self.pendingCommands = pendingCommands
        self.notice = notice
        self.sourceRevisions = sourceRevisions
        self.transportCommandResolutions = transportCommandResolutions
    }
}
