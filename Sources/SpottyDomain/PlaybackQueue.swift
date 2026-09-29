import Foundation

/// One playback occurrence shared by accepted ordering and its queue presentation.
/// Metadata supplies labels; only the selected ordering supplies occurrence identity.
public struct QueueEntry: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public let uri: String
    public let provider: String
    public let occurrence: Int
    /// Connect occurrence uid when the authoritative snapshot supplied one.
    /// Empty for Web/non-authoritative presentation that has not bound a uid.
    public let uid: String

    public init(uri: String, provider: String, occurrence: Int = 0, uid: String = "") {
        id = Self.identity(occurrence: occurrence, provider: provider, uri: uri, uid: uid)
        self.uri = uri
        self.provider = provider
        self.occurrence = occurrence
        self.uid = uid
    }

    /// A Connect occurrence keeps its identity when ordering changes. Without a UID, the
    /// positional fallback deliberately does not promise continuity across reorder.
    public static func identity(occurrence: Int, provider: String, uri: String, uid: String) -> String {
        if uid.isEmpty {
            return "\(occurrence)-\(provider)-\(uri)"
        }
        return "uid-\(uid)-\(provider)-\(uri)"
    }

    /// Malformed duplicate UIDs cannot produce duplicate SwiftUI row IDs. Their original UID
    /// remains available to the mutation policy, which refuses ambiguous protocol identities.
    public static func uniquelyIdentified(_ entries: [Self]) -> [Self] {
        let counts = Dictionary(entries.map { ($0.id, 1) }, uniquingKeysWith: +)
        return entries.enumerated().map { index, entry in
            guard counts[entry.id, default: 0] > 1 else { return entry }
            return Self(entry, id: "ambiguous-\(index)-\(entry.id)")
        }
    }

    private init(_ entry: Self, id: String) {
        self.id = id
        uri = entry.uri
        provider = entry.provider
        occurrence = entry.occurrence
        uid = entry.uid
    }

    /// What fed this entry, in listener-facing words.
    public var sourceLabel: String {
        if provider == "web-api" { return "Up next" }
        if provider.contains("queue") { return "From your queue" }
        if provider.contains("autoplay") { return "Suggested by Spotify" }
        return "From the current context"
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
    public var entries: [QueueEntry]
    public var source: PlaybackQueueSource
    public var completeness: PlaybackQueueCompleteness
    public var revision: UInt64
    public var receivedAt: Date
    public var contextURI: String?

    public init(
        entries: [QueueEntry] = [],
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
