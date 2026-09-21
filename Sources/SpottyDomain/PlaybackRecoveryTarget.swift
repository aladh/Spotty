import Foundation

/// Evidence required from an explicit selection after a refused resume. Kept with the existing
/// command intent, so acknowledgement, cancellation and presentation cannot release the block.
public struct PlaybackRecoveryTarget: Equatable, Sendable {
    public enum Selection: Equatable, Sendable {
        case track(String)
        case context(String)
    }

    public let selection: Selection
    public let engineGeneration: UInt64
    public let local: Bool

    public init(selection: Selection, engineGeneration: UInt64, local: Bool) {
        self.selection = selection
        self.engineGeneration = engineGeneration
        self.local = local
    }

    func matches(_ snapshot: EnginePlaybackSnapshot, envelope: PlaybackEventEnvelope, dispatchedAt: Date) -> Bool {
        guard envelope.engineEpoch == engineGeneration,
            snapshot.contextURI != nil, snapshot.isActiveDevice == local,
            snapshot.transport == .playing, !snapshot.trackUnavailable,
            let track = snapshot.trackURI, !track.isEmpty,
            snapshot.timing.position >= 0,
            snapshot.timing.position <= max(0, envelope.receivedAt.timeIntervalSince(dispatchedAt)) + 1
        else { return false }
        switch selection {
        case let .track(uri): return track == uri
        case let .context(uri): return snapshot.contextURI == uri
        }
    }
}
