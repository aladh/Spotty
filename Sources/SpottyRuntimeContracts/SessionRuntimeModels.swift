import Foundation
import SpottyDomain

/// The desktop contract contains presentation and intent, never credentials, engine handles or PCM.
public struct SessionSnapshot: Codable, Equatable, Sendable {
    /// Command replay namespace. It may renew without changing the account epoch; clients must
    /// resynchronize from a complete snapshot and must not replay old-session commands.
    public var sessionID: UUID
    public var revision: UInt64
    public var accountEpoch: UInt64
    public var routeRevision: UInt64
    public var phase: PlaybackSessionPhase
    public var owner: PlaybackOwner
    public var presentation: PlaybackPresentationSnapshot
    public var options: PlaybackOptions
    public var queue: PlaybackQueueSnapshot
    public var devices: PlaybackDeviceSnapshot
    public var capabilities: Set<SessionCommandKind>
    public var receipts: [SessionCommandReceipt]
    public var needsReauthentication: Bool
    public var isRetiring: Bool

    public init(
        sessionID: UUID, revision: UInt64, accountEpoch: UInt64 = 0, routeRevision: UInt64 = 0,
        phase: PlaybackSessionPhase = .signedOut, owner: PlaybackOwner = .none,
        presentation: PlaybackPresentationSnapshot = .init(
            currentTrack: nil, transport: .stopped, timing: .init(anchoredAt: .distantPast)),
        options: PlaybackOptions = .init(), queue: PlaybackQueueSnapshot = .init(),
        devices: PlaybackDeviceSnapshot = .init(), capabilities: Set<SessionCommandKind> = [],
        receipts: [SessionCommandReceipt] = [], needsReauthentication: Bool = false, isRetiring: Bool = false
    ) {
        self.sessionID = sessionID
        self.revision = revision
        self.accountEpoch = accountEpoch
        self.routeRevision = routeRevision
        self.phase = phase
        self.owner = owner
        self.presentation = presentation
        self.options = options
        self.queue = queue
        self.devices = devices
        self.capabilities = capabilities
        self.receipts = receipts
        self.needsReauthentication = needsReauthentication
        self.isRetiring = isRetiring
    }
}

public enum SessionCommandKind: String, Codable, CaseIterable, Sendable {
    case account, play, transport, navigation, seek, options, transfer, queueAppend, queueRemove, queueRefresh
}

public enum SessionAction: Codable, Equatable, Sendable {
    case restore, connect, reauthorize, cancelConnect, logout
    case playURI(String)
    case playTracks([CatalogTrack], contextURI: String?)
    case togglePlayback, next, previous
    case seek(fraction: Double)
    case toggleShuffle, cycleRepeat
    case transfer(ConnectDevice)
    case addToQueue([String])
    case removeUpcoming(selectedIDs: Set<String>)
    case refreshQueue, cancelQueueRefresh

    public var kind: SessionCommandKind {
        switch self {
        case .restore, .connect, .reauthorize, .cancelConnect, .logout: .account
        case .playURI, .playTracks: .play
        case .togglePlayback: .transport
        case .next, .previous: .navigation
        case .seek: .seek
        case .toggleShuffle, .cycleRepeat: .options
        case .transfer: .transfer
        case .addToQueue: .queueAppend
        case .removeUpcoming: .queueRemove
        case .refreshQueue, .cancelQueueRefresh: .queueRefresh
        }
    }

    /// Even account operations can have irreversible effects. An uncertain result is never retried.
    public var mayWrite: Bool { kind != .queueRefresh }
}

public struct SessionCommand: Codable, Equatable, Sendable {
    public let id: UUID
    /// The namespace observed when this intent was created. Never rewrite it to retry an
    /// uncertain command after the runtime renews its session.
    public let sessionID: UUID
    public let expectedRouteRevision: UInt64?
    public let action: SessionAction

    public init(
        id: UUID = UUID(), sessionID: UUID, expectedRouteRevision: UInt64? = nil, action: SessionAction
    ) {
        self.id = id
        self.sessionID = sessionID
        self.expectedRouteRevision = expectedRouteRevision
        self.action = action
    }
}

public enum SessionCommandDisposition: String, Codable, Sendable {
    case admitted, dispatched, sent, observedConfirmed, rejected, superseded, expired, unknown

    public var isTerminal: Bool {
        switch self {
        case .admitted, .dispatched, .sent: false
        case .observedConfirmed, .rejected, .superseded, .expired, .unknown: true
        }
    }
}

public struct SessionCommandReceipt: Codable, Equatable, Sendable {
    public let commandID: UUID
    public let sessionID: UUID
    public let disposition: SessionCommandDisposition
    public let message: String?

    public init(commandID: UUID, sessionID: UUID, disposition: SessionCommandDisposition, message: String? = nil) {
        self.commandID = commandID
        self.sessionID = sessionID
        self.disposition = disposition
        self.message = message
    }
}

/// Subscription starts with a complete snapshot. Buffer drops are detectable by revision gaps.
/// Runtime implementations serialize admission and revalidate account and route before dispatch.
public protocol SessionRuntimeServing: Sendable {
    func snapshot() async -> SessionSnapshot
    func submit(_ command: SessionCommand) async -> SessionCommandReceipt
    func subscribe() async -> AsyncStream<SessionSnapshot>
}
