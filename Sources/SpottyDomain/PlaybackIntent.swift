import Foundation

/// Transport acceptance is not observed success. Terminal results are immutable, including a
/// timeout: a later snapshot still updates playback truth but cannot claim an operation was undone.
public enum PlaybackIntentOutcome: Equatable, Sendable {
    case admitted, dispatched, sent, observedConfirmed, rejected, superseded, timedOut

    public var isTerminal: Bool {
        switch self {
        case .admitted, .dispatched, .sent: false
        default: true
        }
    }
}

public struct PlaybackIntent: Equatable, Sendable {
    public let command: PendingPlaybackCommand
    public let baselineTrackURI: String?
    public var baselinePosition: TimeInterval? = nil
    public var localTransferTargetID: String? = nil
    public var baselineOwner: PlaybackOwner? = nil
    public var queueMinimumCounts: [String: Int]? = nil
    public var removedQueueUIDs: Set<String>? = nil
    public var queueContextURI: String? = nil
    public var queueRevision: UInt64 = 0
    public var outcome: PlaybackIntentOutcome = .admitted
    public var dispatchedAt: Date?
    public var settledAt: Date?

    public init(command: PendingPlaybackCommand, baselineTrackURI: String?) {
        self.command = command
        self.baselineTrackURI = baselineTrackURI
    }

    public mutating func settle(_ result: PlaybackIntentOutcome, at date: Date) {
        guard !outcome.isTerminal else { return }
        outcome = result
        if result.isTerminal { settledAt = date }
    }

    /// Evidence only from an accepted engine payload received after dispatch, never optimistic
    /// state, metadata, or preferences. Spotify does not echo the local operation ID; this proves
    /// an observed match, not causation. Navigation matches a track change or position restart;
    /// an unchanged same-track sample cannot confirm an unknown target.
    public mutating func observe(_ envelope: PlaybackEventEnvelope) {
        guard let dispatchedAt, envelope.receivedAt >= dispatchedAt, !outcome.isTerminal else { return }
        switch envelope.event {
        case let .enginePlayback(snapshot) where envelope.source == .enginePlayback:
            guard command.kind != .queue, command.kind != .transfer else { return }
            let uri = snapshot.trackURI.flatMap { $0.isEmpty ? nil : $0 }
            if command.kind == .navigation, command.expectedTrack == nil {
                guard let uri, let baselineTrackURI, !snapshot.trackUnavailable else { return }
                if uri != baselineTrackURI || baselinePosition.map({ snapshot.timing.position + 1 < $0 }) == true {
                    settle(.observedConfirmed, at: envelope.receivedAt)
                }
                return
            }
            if let target = command.expectedTrack?.uri ?? command.expectedTrackURI {
                if uri != target {
                    if uri != baselineTrackURI { settle(.superseded, at: envelope.receivedAt) }
                    return
                }
            } else if let baselineTrackURI, uri != baselineTrackURI {
                settle(.superseded, at: envelope.receivedAt)
                return
            }
            if snapshot.trackUnavailable { settle(.rejected, at: envelope.receivedAt); return }
            if let transport = command.expectedTransport, snapshot.transport != transport { return }
            if let shuffle = command.expectedShuffle, snapshot.shuffle != shuffle { return }
            if let flags = command.expectedRepeatFlags, snapshot.repeatFlags != flags {
                if let incoming = snapshot.repeatFlags, let previous = command.rollbackRepeatFlags,
                    incoming != previous,
                    !PlaybackReducer.isRepeatTransitionIntermediate(
                        previous: previous, target: flags, incoming: incoming)
                {
                    settle(.superseded, at: envelope.receivedAt)
                }
                return
            }
            if command.kind == .seek, let timing = command.expectedTiming,
                !PlaybackReducer.matchesExpectedSeekPosition(snapshot.timing, timing)
            {
                return
            }
            guard command.expectedOwner == nil,
                command.expectedTransport != nil || command.expectedTrack != nil
                    || command.expectedShuffle != nil || command.expectedRepeatFlags != nil
                    || command.expectedTiming != nil
            else { return }
            settle(.observedConfirmed, at: envelope.receivedAt)
        case let .engineConnection(snapshot) where envelope.source == .engineConnection:
            observeOwner(snapshot.owner, at: envelope.receivedAt)
        case let .devices(snapshot) where envelope.source == .engineDevices:
            guard let active = snapshot.devices.first(where: \.isActive) else { return }
            observeOwner(
                active.id == snapshot.localDeviceID ? .local(active) : .remote(active), at: envelope.receivedAt)
        case let .queue(snapshot) where envelope.source == .engineQueue:
            guard snapshot.source == .connect, snapshot.completeness == .complete,
                snapshot.revision > queueRevision, snapshot.receivedAt >= dispatchedAt,
                snapshot.contextURI == queueContextURI
            else { return }
            if let counts = queueMinimumCounts {
                let observed = Dictionary(grouping: snapshot.entries, by: \.uri).mapValues(\.count)
                if counts.allSatisfy({ observed[$0.key, default: 0] >= $0.value }) {
                    settle(.observedConfirmed, at: envelope.receivedAt)
                }
            }
            if let removedQueueUIDs,
                removedQueueUIDs.isDisjoint(with: Set(snapshot.entries.map(\.uid)))
            {
                settle(.observedConfirmed, at: envelope.receivedAt)
            }
        default: break
        }
    }
    private mutating func observeOwner(_ owner: PlaybackOwner, at date: Date) {
        if command.kind != .transfer {
            if let baseline = baselineOwner.flatMap(PlaybackReducer.playbackOwnerStableDeviceID),
                PlaybackReducer.playbackOwnerStableDeviceID(owner) != baseline
            {
                settle(.superseded, at: date)
            }
            return
        }
        guard
            let targetID = command.expectedOwner.flatMap(PlaybackReducer.playbackOwnerStableDeviceID)
                ?? localTransferTargetID
        else { return }
        let incomingID = PlaybackReducer.playbackOwnerStableDeviceID(owner)
        if incomingID == targetID {
            if PlaybackReducer.isIdentifiedPlaybackOwner(owner) { settle(.observedConfirmed, at: date) }
        } else if incomingID != baselineOwner.flatMap(PlaybackReducer.playbackOwnerStableDeviceID) {
            settle(.superseded, at: date)
        }
    }

}
