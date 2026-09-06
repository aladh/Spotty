import Foundation

/// One Connect-protocol queue row, including delimiters and autoplay that presentation hides.
/// Occurrence identity for removal is the upcoming projection index bound to a Connect uid
/// when the snapshot supplies one, never URI equality alone.
public struct QueueProtocolTrack: Equatable, Sendable {
    public let uri: String
    public let uid: String
    public let provider: String
    /// Exact incoming Connect metadata map. Must not be synthesized on encode.
    public let metadata: [String: String]
    public let removed: [String]
    public let blocked: [String]
    /// Repeated-string restriction fields keyed as Connect JSON (`disallow_*_reasons`).
    public let restrictions: [String: [String]]
    public let albumURI: String
    public let disallowReasons: [String]
    public let artistURI: String

    public init(
        uri: String,
        uid: String = "",
        provider: String,
        metadata: [String: String] = [:],
        removed: [String] = [],
        blocked: [String] = [],
        restrictions: [String: [String]] = [:],
        albumURI: String = "",
        disallowReasons: [String] = [],
        artistURI: String = ""
    ) {
        self.uri = uri
        self.uid = uid
        self.provider = provider
        self.metadata = metadata
        self.removed = removed
        self.blocked = blocked
        self.restrictions = restrictions
        self.albumURI = albumURI
        self.disallowReasons = disallowReasons
        self.artistURI = artistURI
    }
}

/// Authoritative Connect queue replacement payload. Presentation snapshots must not be
/// substituted for this: Web API metadata can change labels without carrying `prev_tracks`,
/// UIDs, delimiters, or restriction flags.
public struct QueueMutationSnapshot: Equatable, Sendable {
    public var accountEpoch: UInt64
    public var engineEpoch: UInt64
    public var sourceRevision: UInt64
    public var source: PlaybackQueueSource
    public var completeness: PlaybackQueueCompleteness
    public var provisional: Bool
    public var next: [QueueProtocolTrack]
    public var prev: [QueueProtocolTrack]
    public var queueRevision: String
    public var disallowSetQueue: Bool
    public var disallowRemovingFromNextTracks: Bool

    public init(
        accountEpoch: UInt64,
        engineEpoch: UInt64 = 0,
        sourceRevision: UInt64,
        source: PlaybackQueueSource,
        completeness: PlaybackQueueCompleteness,
        provisional: Bool,
        next: [QueueProtocolTrack],
        prev: [QueueProtocolTrack],
        queueRevision: String,
        disallowSetQueue: Bool = false,
        disallowRemovingFromNextTracks: Bool = false
    ) {
        self.accountEpoch = accountEpoch
        self.engineEpoch = engineEpoch
        self.sourceRevision = sourceRevision
        self.source = source
        self.completeness = completeness
        self.provisional = provisional
        self.next = next
        self.prev = prev
        self.queueRevision = queueRevision
        self.disallowSetQueue = disallowSetQueue
        self.disallowRemovingFromNextTracks = disallowRemovingFromNextTracks
    }
}

/// Why a queue replacement must not be sent. Messages are privacy-safe and stable.
public enum QueueMutationRefusal: Equatable, Sendable, Error {
    case notConnected
    case joiningConnect
    case needsDeviceSelection
    case incompleteProvenance
    case provisional
    case restricted
    case localOwnerUnsupported
    case staleIdentities
    case nothingSelected
    case nowPlayingOrHistory

    public var feedbackMessage: String {
        switch self {
        case .notConnected:
            "Connect Spotify before changing the queue."
        case .joiningConnect:
            "Spotty is still joining Spotify Connect."
        case .needsDeviceSelection:
            "Choose a playback device. Select This computer in the device picker to play on this Mac."
        case .incompleteProvenance, .provisional:
            "The queue isn’t complete enough to edit safely."
        case .restricted:
            "Spotify isn’t allowing queue changes right now."
        case .localOwnerUnsupported:
            "This Mac can’t remove queued songs while it owns playback."
        case .staleIdentities:
            "That queue selection is no longer current."
        case .nothingSelected, .nowPlayingOrHistory:
            "Nothing removable is selected in the queue."
        }
    }
}

public struct QueueReplacement: Equatable, Sendable {
    public let next: [QueueProtocolTrack]
    public let prev: [QueueProtocolTrack]
    public let queueRevision: String
    public let removedCount: Int

    public init(
        next: [QueueProtocolTrack],
        prev: [QueueProtocolTrack],
        queueRevision: String,
        removedCount: Int
    ) {
        self.next = next
        self.prev = prev
        self.queueRevision = queueRevision
        self.removedCount = removedCount
    }
}

/// Sequential `add_to_queue` is not atomic. Feedback reports how many commands completed.
public enum QueueAddFeedbackKind: Equatable, Sendable {
    case success
    case informational
    case failure
}

public struct QueueAddFeedback: Equatable, Sendable {
    public let kind: QueueAddFeedbackKind
    public let message: String
}

public enum QueueAddFeedbackPolicy: Sendable {
    public static func evaluate(requested: Int, completed: Int) -> QueueAddFeedback? {
        guard requested > 0, completed >= 0, completed <= requested else { return nil }
        if completed == requested {
            return QueueAddFeedback(
                kind: .success,
                message: requested == 1 ? "Added to Queue" : "Added \(requested) songs to Queue"
            )
        }
        if completed == 0 {
            return QueueAddFeedback(
                kind: .failure,
                message: requested == 1
                    ? "Could not add that track to the queue."
                    : "Could not add those tracks to the queue."
            )
        }
        return QueueAddFeedback(
            kind: .informational,
            message: "Added \(completed) of \(requested) songs to Queue"
        )
    }
}

/// librespot a1b66d3 `Spirc` publishes `add_to_queue` and `clear_queue`, but not
/// selected-occurrence removal. Incoming dealer `SetQueue` is handled internally
/// (`connect_state.handle_set_queue`) and is not a public local command.
/// Routing HTTP `set_queue` to the local device is unproven without a live Connect mutation
/// and would invent a second owner beside Spirc. Local-owner removal is therefore disabled
/// until a tested Spirc replacement export exists.
public enum LocalQueueReplacementCapability: Sendable {
    public static let isSupported = false
    public static let evidence = """
        librespot Spirc at a1b66d3c8a14e55a9572a9e17467150dca618c9a exposes add_to_queue, \
        clear_queue, load, play/pause, skip, shuffle, repeat, transfer, activate, and disconnect. \
        SetQueueCommand is \
        inbound-only (spirc.rs handle of dealer SetQueue). Device is_restricted in Spotty's cluster \
        mapping is hardcoded false and is not a restriction signal. Follow-up: a panic-barrier FFI \
        that performs the same connect_state.set_next_tracks/set_prev_tracks replacement Spirc \
        already applies for remote SetQueue, or a proven same-device HTTP set_queue path.
        """
}

/// Occurrence-safe upcoming-queue selection. History and now-playing are never part of the
/// upcoming projection, so they cannot be targeted by this command.
public enum QueueMutationSelection: Sendable {
    public enum KeyboardCommand: Equatable, Sendable {
        case removeUpcomingOccurrences
    }

    /// Upcoming rows in visible order. `selectedIDs` is a set, so a row cannot be emitted twice.
    public static func orderedUpcoming(
        selectedIDs: Set<String>,
        in upcoming: [QueueEntry]
    ) -> [QueueEntry] {
        upcoming.filter { selectedIDs.contains($0.id) }
    }

    public static func addURIs(from tracks: [CatalogTrack]) -> [String] {
        tracks.map(\.uri).filter { !$0.isEmpty }
    }

    public static func keyboardCommand(
        deleteOrBackspace: Bool,
        selectedUpcomingCount: Int,
        isRemovalAllowed: Bool
    ) -> KeyboardCommand? {
        guard deleteOrBackspace, selectedUpcomingCount > 0, isRemovalAllowed else {
            return nil
        }
        return .removeUpcomingOccurrences
    }
}

public enum QueueProtocolProjection: Sendable {
    /// Playable Connect rows that may appear in the upcoming rail or as current-track identity.
    public static func isPlayableTrackURI(_ uri: String) -> Bool {
        uri.hasPrefix("spotify:track:")
    }

    /// App-facing upcoming rows from unfiltered Connect protocol `next` tracks.
    ///
    /// Stop at `spotify:delimiter`, keep playable tracks, and ignore episodes or other
    /// non-track URIs. Protocol rows after the delimiter (autoplay continuation) stay in
    /// the mutation snapshot and must not appear in the queue rail.
    public static func upcoming(from protocolNext: [QueueProtocolTrack]) -> [QueueProtocolTrack] {
        var items: [QueueProtocolTrack] = []
        for track in protocolNext {
            if track.uri == "spotify:delimiter" { break }
            if isPlayableTrackURI(track.uri) {
                items.append(track)
            }
        }
        return items
    }

    /// Occurrence-indexed presentation rows derived from protocol `next` tracks.
    public static func upcomingEntries(from protocolNext: [QueueProtocolTrack]) -> [QueueEntry] {
        upcoming(from: protocolNext).enumerated().map { index, track in
            QueueEntry(uri: track.uri, provider: track.provider, occurrence: index, uid: track.uid)
        }
    }

    public static func matchesVisibleUpcoming(
        protocolNext: [QueueProtocolTrack],
        visible: [QueueEntry]
    ) -> Bool {
        upcoming(from: protocolNext).map(\.uri) == visible.map(\.uri)
    }

    /// Bound occurrence identity: Connect uid when present, otherwise a unique URI.
    /// Duplicate UIDs, duplicate URIs without uids, or uid drift fail closed.
    public static func identitiesAreProven(
        protocolNext: [QueueProtocolTrack],
        visible: [QueueEntry]
    ) -> Bool {
        let upcoming = upcoming(from: protocolNext)
        guard upcoming.count == visible.count else { return false }
        let nonEmptyUIDs = upcoming.map(\.uid).filter { !$0.isEmpty }
        if Set(nonEmptyUIDs).count != nonEmptyUIDs.count {
            return false
        }
        for (proto, row) in zip(upcoming, visible) {
            guard proto.uri == row.uri else { return false }
            if !row.uid.isEmpty {
                if proto.uid != row.uid { return false }
                continue
            }
            if proto.uid.isEmpty {
                if upcoming.filter({ $0.uri == proto.uri }).count != 1 { return false }
            } else if upcoming.filter({ $0.uri == proto.uri }).count != 1 {
                return false
            }
        }
        return true
    }

    /// Removes selected upcoming occurrences from the protocol `next` list by proven
    /// identity, preserving delimiters, autoplay, and `prev_tracks`.
    public static func removingUpcomingOccurrences(
        selectedIDs: Set<String>,
        visibleUpcoming: [QueueEntry],
        protocolNext: [QueueProtocolTrack]
    ) -> [QueueProtocolTrack]? {
        let selected = QueueMutationSelection.orderedUpcoming(
            selectedIDs: selectedIDs,
            in: visibleUpcoming
        )
        guard !selected.isEmpty else { return nil }
        guard matchesVisibleUpcoming(protocolNext: protocolNext, visible: visibleUpcoming) else {
            return nil
        }
        guard identitiesAreProven(protocolNext: protocolNext, visible: visibleUpcoming) else {
            return nil
        }

        let selectedIndices = Set(
            visibleUpcoming.enumerated().compactMap { index, entry in
                selectedIDs.contains(entry.id) ? index : nil
            }
        )
        guard !selectedIndices.isEmpty else { return nil }

        var upcomingIndex = 0
        var remaining: [QueueProtocolTrack] = []
        remaining.reserveCapacity(protocolNext.count)
        var pastDelimiter = false
        for track in protocolNext {
            if pastDelimiter {
                remaining.append(track)
                continue
            }
            if track.uri == "spotify:delimiter" {
                remaining.append(track)
                pastDelimiter = true
                continue
            }
            if isPlayableTrackURI(track.uri) {
                if selectedIndices.contains(upcomingIndex) {
                    upcomingIndex += 1
                    continue
                }
                upcomingIndex += 1
            }
            remaining.append(track)
        }
        return remaining
    }
}

public enum QueueMutationPolicy: Sendable {
    public static func evaluateRemoval(
        selectedIDs: Set<String>,
        visibleUpcoming: [QueueEntry],
        nowPlayingID: String?,
        historyIDs: Set<String>,
        mutation: QueueMutationSnapshot?,
        route: ConnectCommandRoute,
        isConnected: Bool,
        accountEpoch: UInt64,
        engineEpoch: UInt64,
        localReplacementSupported: Bool = LocalQueueReplacementCapability.isSupported
    ) -> Result<QueueReplacement, QueueMutationRefusal> {
        if !isConnected { return .failure(.notConnected) }
        if selectedIDs.isEmpty { return .failure(.nothingSelected) }
        if let nowPlayingID, selectedIDs.contains(nowPlayingID),
            selectedIDs.isSubset(of: [nowPlayingID])
        {
            return .failure(.nowPlayingOrHistory)
        }
        if !selectedIDs.isDisjoint(with: historyIDs), selectedIDs.isSubset(of: historyIDs) {
            return .failure(.nowPlayingOrHistory)
        }

        let upcomingIDs = Set(visibleUpcoming.map(\.id))
        let targeted = selectedIDs.intersection(upcomingIDs)
        if targeted.isEmpty {
            if let nowPlayingID, selectedIDs.contains(nowPlayingID) {
                return .failure(.nowPlayingOrHistory)
            }
            if !selectedIDs.isDisjoint(with: historyIDs) {
                return .failure(.nowPlayingOrHistory)
            }
            return .failure(.staleIdentities)
        }
        if targeted != selectedIDs { return .failure(.staleIdentities) }

        switch route {
        case .waitingForLocalIdentity:
            return .failure(.joiningConnect)
        case .needsDeviceSelection:
            return .failure(.needsDeviceSelection)
        case .local:
            if !localReplacementSupported {
                return .failure(.localOwnerUnsupported)
            }
        case .remote:
            break
        }

        guard let mutation else { return .failure(.incompleteProvenance) }
        guard mutation.accountEpoch == accountEpoch, mutation.engineEpoch == engineEpoch else {
            return .failure(.staleIdentities)
        }
        guard !mutation.provisional, mutation.source != .provisional else {
            return .failure(.provisional)
        }
        guard mutation.source == .connect,
            mutation.completeness == .complete
        else {
            return .failure(.incompleteProvenance)
        }
        guard !mutation.disallowSetQueue, !mutation.disallowRemovingFromNextTracks else {
            return .failure(.restricted)
        }
        guard
            QueueProtocolProjection.matchesVisibleUpcoming(
                protocolNext: mutation.next,
                visible: visibleUpcoming
            )
        else {
            return .failure(.incompleteProvenance)
        }
        guard
            QueueProtocolProjection.identitiesAreProven(
                protocolNext: mutation.next,
                visible: visibleUpcoming
            )
        else {
            return .failure(.staleIdentities)
        }
        guard
            let remaining = QueueProtocolProjection.removingUpcomingOccurrences(
                selectedIDs: targeted,
                visibleUpcoming: visibleUpcoming,
                protocolNext: mutation.next
            )
        else {
            return .failure(.staleIdentities)
        }
        let removedCount = mutation.next.count - remaining.count
        guard removedCount > 0 else { return .failure(.nothingSelected) }
        return .success(
            QueueReplacement(
                next: remaining,
                prev: mutation.prev,
                queueRevision: mutation.queueRevision,
                removedCount: removedCount
            ))
    }
}
