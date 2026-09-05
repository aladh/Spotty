import Foundation

/// App-facing engine playback from protocol playing/paused flags.
///
/// The engine reports `is_playing`, `is_paused`, track URI, timing, and options.
/// Transport, empty-URI identity, and timestamp correction are Swift-owned. Resume-load
/// target ordering is captured separately by `ResumeLoadPlan`.
public enum PlaybackSnapshotProjection: Sendable {
    /// Empty wire URIs are missing, not a distinct identity.
    public static func resolvedTrackURI(_ uri: String) -> String? {
        uri.isEmpty ? nil : uri
    }

    public static func isAudible(isPlaying: Bool, isPaused: Bool) -> Bool {
        isPlaying && !isPaused
    }

    /// The first snapshot on this device must not present playing: cluster state can
    /// still say the local player is active while audio has not started, and treating
    /// that as live would interpolate a stale playhead.
    ///
    /// Audible flags outrank a missing track URI. Cluster `PlayerState` can omit `track`
    /// while `is_playing` is already true; flashing `.stopped` would hide live audio
    /// until identity arrives.
    public static func transport(
        isPlaying: Bool,
        isPaused: Bool,
        trackURI: String,
        isInitialSnapshot: Bool,
        isActiveDevice: Bool
    ) -> PlaybackTransportState {
        if isAudible(isPlaying: isPlaying, isPaused: isPaused),
            !(isInitialSnapshot && isActiveDevice)
        {
            return .playing
        }
        return resolvedTrackURI(trackURI) == nil ? .stopped : .paused
    }

    public static func snapshot(
        isPlaying: Bool,
        isPaused: Bool,
        trackURI: String,
        positionMilliseconds: Int64,
        durationMilliseconds: Int64,
        timestampMilliseconds: Int64?,
        shuffle: Bool?,
        repeatContext: Bool,
        repeatTrack: Bool,
        trackUnavailable: Bool = false,
        isInitialSnapshot: Bool,
        isActiveDevice: Bool,
        receivedAt: Date,
        contextURI: String? = nil
    ) -> EnginePlaybackSnapshot {
        let transport = transport(
            isPlaying: isPlaying,
            isPaused: isPaused,
            trackURI: trackURI,
            isInitialSnapshot: isInitialSnapshot,
            isActiveDevice: isActiveDevice
        )
        let flags = RepeatFlags(context: repeatContext, track: repeatTrack)
        let resolvedURI = resolvedTrackURI(trackURI)
        return EnginePlaybackSnapshot(
            transport: transport,
            trackURI: resolvedURI,
            timing: PlaybackTiming(
                position: playbackSnapshotPosition(
                    positionMilliseconds: positionMilliseconds,
                    durationMilliseconds: durationMilliseconds,
                    timestampMilliseconds: timestampMilliseconds,
                    isPlaying: transport == .playing,
                    now: receivedAt
                ),
                duration: TimeInterval(max(0, durationMilliseconds)) / 1_000,
                anchoredAt: receivedAt
            ),
            // The Rust flag is meaningful only for a local active observation with a concrete
            // track identity. This prevents remote and empty-URI samples from becoming notices.
            trackUnavailable: trackUnavailable && isActiveDevice && resolvedURI != nil,
            shuffle: shuffle,
            repeatMode: RepeatMode(context: flags.context, track: flags.track),
            repeatFlags: flags,
            contextURI: contextURI
        )
    }
}
