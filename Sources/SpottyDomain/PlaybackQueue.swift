import Foundation

public struct PlaybackQueueItem: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public let uri: String
    public let provider: String
    public let occurrence: Int
    public let uid: String

    public init(uri: String, provider: String, occurrence: Int = 0, uid: String = "") {
        id = QueueEntry.identity(occurrence: occurrence, provider: provider, uri: uri, uid: uid)
        self.uri = uri
        self.provider = provider
        self.occurrence = occurrence
        self.uid = uid
    }

    public init(_ entry: QueueEntry) {
        self.init(uri: entry.uri, provider: entry.provider, occurrence: entry.occurrence, uid: entry.uid)
    }
}

public enum PlaybackQueueSource: Int, Comparable, Sendable, Codable {
    case none = 0
    case provisional = 1
    case connect = 2
    case webAPI = 3

    public static func < (lhs: PlaybackQueueSource, rhs: PlaybackQueueSource) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum PlaybackQueueCompleteness: Int, Comparable, Sendable, Codable {
    case metadataOnly = 0
    case partial = 1
    case complete = 2

    public static func < (lhs: PlaybackQueueCompleteness, rhs: PlaybackQueueCompleteness) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct PlaybackQueueSnapshot: Equatable, Sendable, Codable {
    public var entries: [PlaybackQueueItem]
    public var source: PlaybackQueueSource
    public var completeness: PlaybackQueueCompleteness
    public var revision: UInt64
    public var receivedAt: Date
    public var contextURI: String?

    public init(
        entries: [PlaybackQueueItem] = [],
        source: PlaybackQueueSource = .none,
        completeness: PlaybackQueueCompleteness = .partial,
        revision: UInt64 = 0,
        receivedAt: Date = .distantPast,
        contextURI: String? = nil
    ) {
        self.entries = entries
        self.source = source
        self.completeness = completeness
        self.revision = revision
        self.receivedAt = receivedAt
        self.contextURI = contextURI
    }
}

public struct PlaybackDeviceSnapshot: Equatable, Sendable, Codable {
    public var devices: [PlaybackDevice]
    public var localDeviceID: String?
    public var revision: UInt64
    /// Remembered remote device stamped by the store at event intake. The reducer uses this
    /// only as payload; it does not read preferences.
    public var lastRemoteDeviceID: String?

    public init(
        devices: [PlaybackDevice] = [],
        localDeviceID: String? = nil,
        revision: UInt64 = 0,
        lastRemoteDeviceID: String? = nil
    ) {
        self.devices = devices
        self.localDeviceID = localDeviceID
        self.revision = revision
        self.lastRemoteDeviceID = lastRemoteDeviceID
    }
}

/// The one queue-ordering precedence policy used by both the reducer and live queue service.
/// Complete Connect occurrence order is authoritative for a playback context. Web API and
/// catalog metadata may enrich labels, but they must not reorder or replace that list, and
/// they must not copy their revision or receivedAt onto the Connect ordering snapshot.
public func mergePlaybackQueueSnapshots(
    current: PlaybackQueueSnapshot,
    incoming: PlaybackQueueSnapshot
) -> PlaybackQueueSnapshot {
    if current.contextURI != incoming.contextURI {
        return incoming.receivedAt >= current.receivedAt ? incoming : current
    }
    if let preserved = preservingConnectOccurrenceOrder(current: current, incoming: incoming) {
        return preserved
    }
    if incoming.source > current.source { return incoming }
    if incoming.source < current.source { return current }
    if incoming.revision > current.revision { return incoming }
    if incoming.revision < current.revision { return current }
    return incoming.completeness >= current.completeness ? incoming : current
}

/// Same-context Web snapshots may ride along for metadata elsewhere. They do not become
/// the occurrence list, and they do not share a revision/receivedAt clock with Connect.
private func preservingConnectOccurrenceOrder(
    current: PlaybackQueueSnapshot,
    incoming: PlaybackQueueSnapshot
) -> PlaybackQueueSnapshot? {
    let currentConnect = current.source == .connect && current.completeness == .complete
    let incomingConnect = incoming.source == .connect && incoming.completeness == .complete
    if currentConnect, incoming.source == .webAPI {
        return current
    }
    if incomingConnect, current.source == .webAPI {
        return incoming
    }
    return nil
}
