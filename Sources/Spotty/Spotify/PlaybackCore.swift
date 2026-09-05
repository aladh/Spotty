import SpottyDomain
import SpottyPlaybackCore
import Foundation

/// The complete Swift-facing boundary to Spotty's embedded playback engine.
///
/// The application is native SwiftUI, and all catalog, authentication, state, and rendering
/// policy stays in Swift. The bundled Rust/librespot library is deliberately a leaf dependency:
/// only this file knows its C symbol names or result type.
nonisolated enum PlaybackCore {
    typealias Result = SpottyPlaybackResult

    static func registerAudioDataCallback(_ callback: AudioDataCallback) {
        spotty_playback_register_audio_data_callback(callback)
    }

    static func registerAudioControlCallback(_ callback: AudioControlCallback) {
        spotty_playback_register_audio_control_callback(callback)
    }

    static func registerPlaybackStateCallback(_ callback: PlaybackStateCallback) {
        spotty_playback_register_playback_state_callback(callback)
    }

    static func playbackState(
        from pointer: UnsafePointer<SpottyPlaybackSnapshot>?
    ) -> RustPlaybackState? {
        guard let pointer else { return nil }
        let snapshot = pointer.pointee
        return RustPlaybackState(
            revision: snapshot.revision,
            sessionGeneration: snapshot.session_generation,
            isPlaying: snapshot.is_playing != 0,
            isPaused: snapshot.is_paused != 0,
            trackURI: optionalCString(snapshot.track_uri) ?? "",
            positionMS: snapshot.position_ms,
            durationMS: snapshot.duration_ms,
            timestampMS: snapshot.timestamp_ms,
            shuffle: snapshot.shuffle != 0,
            repeatTrack: snapshot.repeat_track != 0,
            repeatContext: snapshot.repeat_context != 0,
            trackUnavailable: snapshot.track_unavailable != 0,
            isActiveDevice: snapshot.is_active_device != 0,
            contextURI: optionalCString(snapshot.context_uri)
        )
    }

    static func registerQueueCallback(_ callback: QueueCallback) {
        spotty_playback_register_queue_callback(callback)
    }

    static func queueState(
        from pointer: UnsafePointer<SpottyQueueSnapshot>?
    ) -> RustQueueState? {
        guard let pointer else { return nil }
        let snapshot = pointer.pointee
        return RustQueueState(
            revision: snapshot.revision,
            sessionGeneration: snapshot.session_generation,
            track: queueItem(
                uri: snapshot.track_uri,
                provider: snapshot.track_provider,
                uid: snapshot.track_uid
            ),
            protocolNextTracks: protocolTracks(
                snapshot.next_tracks,
                count: Int(snapshot.next_count)
            ),
            protocolPrevTracks: protocolTracks(
                snapshot.prev_tracks,
                count: Int(snapshot.prev_count)
            ),
            queueRevision: optionalCString(snapshot.queue_revision) ?? "",
            disallowSetQueue: snapshot.disallow_set_queue != 0,
            disallowRemovingFromNextTracks: snapshot.disallow_removing_from_next_tracks != 0
        )
    }

    static func registerConnectionStateCallback(_ callback: ConnectionStateCallback) {
        spotty_playback_register_connection_state_callback(callback)
    }

    static func connectionState(
        from pointer: UnsafePointer<SpottyConnectionSnapshot>?
    ) -> RustConnectionState? {
        guard let pointer else { return nil }
        let snapshot = pointer.pointee
        return RustConnectionState(
            revision: snapshot.revision,
            sessionGeneration: snapshot.session_generation,
            sessionConnected: snapshot.session_connected != 0,
            spircReady: snapshot.spirc_ready != 0,
            isActiveDevice: snapshot.is_active_device != 0,
            resumePending: snapshot.resume_pending != 0,
            lastError: optionalCString(snapshot.last_error),
            deviceID: optionalCString(snapshot.device_id),
            credentialsRejected: snapshot.credentials_rejected != 0
        )
    }

    static func registerDevicesCallback(_ callback: DevicesCallback) {
        spotty_playback_register_devices_callback(callback)
    }

    static func devicesState(
        from pointer: UnsafePointer<SpottyDevicesSnapshot>?
    ) -> RustDevicesState? {
        guard let pointer else { return nil }
        let snapshot = pointer.pointee
        let count = Int(snapshot.device_count)
        let devices: [ConnectProtocolDevice]
        if count > 0, let base = snapshot.devices {
            devices = UnsafeBufferPointer(start: base, count: count).map { row in
                ConnectProtocolDevice(
                    id: optionalCString(row.id) ?? "",
                    name: optionalCString(row.name) ?? "",
                    type: optionalCString(row.device_type) ?? ""
                )
            }
        } else {
            devices = []
        }
        return RustDevicesState(
            revision: snapshot.revision,
            sessionGeneration: snapshot.session_generation,
            activeDeviceID: optionalCString(snapshot.active_device_id) ?? "",
            devices: devices
        )
    }

    static func authorizeStreaming(with accessToken: String) -> Int32 {
        accessToken.withCString { spotty_playback_authorize_streaming($0) }
    }

    static func initialize() -> Result {
        ConnectDeviceIdentity.current.withCString {
            spotty_playback_set_device_name($0)
        }
        return spotty_playback_init_player(nil)
    }

    static func play(uri: String) -> Result {
        uri.withCString { spotty_playback_play_uri($0) }
    }

    static func play(tracks: [String]) -> Result {
        guard
            let data = try? JSONEncoder().encode(tracks),
            let json = String(data: data, encoding: .utf8)
        else { return .error }

        return json.withCString { spotty_playback_play_tracks($0) }
    }

    static func pause() -> Result { spotty_playback_pause() }
    static func resume() -> Result { spotty_playback_resume() }
    static func resumePositionMilliseconds() -> UInt32 {
        spotty_playback_get_resume_position_ms()
    }

    static func resumeContextURI() -> String? {
        takeOwnedString(spotty_playback_get_resume_context_uri())
    }

    static func resumeTrackURI() -> String? {
        takeOwnedString(spotty_playback_get_resume_track_uri())
    }

    /// `rehydratingSessionGeneration == 0` is a user-resume load. A nonzero value names the
    /// engine session a reconnect rehydration belongs to; the engine declines the load if that
    /// session is no longer current or its window has closed.
    static func load(
        _ target: ResumeLoadPlan.Target,
        rehydratingSessionGeneration: UInt64 = 0
    ) -> Result {
        switch target {
        case let .context(uri, trackHint, positionMS):
            uri.withCString { uriPointer in
                withOptionalCString(trackHint) { hintPointer in
                    spotty_playback_load(
                        uriPointer,
                        hintPointer,
                        positionMS,
                        true,
                        rehydratingSessionGeneration
                    )
                }
            }
        case let .track(uri, positionMS):
            uri.withCString { uriPointer in
                spotty_playback_load(uriPointer, nil, positionMS, false, rehydratingSessionGeneration)
            }
        }
    }

    private static func queueItem(
        uri: UnsafePointer<CChar>?,
        provider: UnsafePointer<CChar>?,
        uid: UnsafePointer<CChar>?
    ) -> RustQueueState.Item? {
        guard let uri = optionalCString(uri) else { return nil }
        return RustQueueState.Item(
            uri: uri,
            provider: optionalCString(provider) ?? "",
            uid: optionalCString(uid) ?? ""
        )
    }

    private static func protocolTracks(
        _ pointer: UnsafePointer<SpottyProtocolQueueTrack>?,
        count: Int
    ) -> [QueueProtocolTrack] {
        guard count > 0, let pointer else { return [] }
        return UnsafeBufferPointer(start: pointer, count: count).map(protocolTrack)
    }

    private static func protocolTrack(_ row: SpottyProtocolQueueTrack) -> QueueProtocolTrack {
        QueueProtocolTrack(
            uri: optionalCString(row.uri) ?? "",
            uid: optionalCString(row.uid) ?? "",
            provider: optionalCString(row.provider) ?? "",
            metadata: stringPairMap(row.metadata, count: Int(row.metadata_count)),
            removed: cStringList(row.removed, count: Int(row.removed_count)),
            blocked: cStringList(row.blocked, count: Int(row.blocked_count)),
            restrictions: restrictionMap(row.restrictions, count: Int(row.restriction_count)),
            albumURI: optionalCString(row.album_uri) ?? "",
            disallowReasons: cStringList(
                row.disallow_reasons,
                count: Int(row.disallow_reason_count)
            ),
            artistURI: optionalCString(row.artist_uri) ?? ""
        )
    }

    private static func stringPairMap(
        _ pointer: UnsafePointer<SpottyStringPair>?,
        count: Int
    ) -> [String: String] {
        guard count > 0, let pointer else { return [:] }
        var map: [String: String] = [:]
        for pair in UnsafeBufferPointer(start: pointer, count: count) {
            guard let key = optionalCString(pair.key) else { continue }
            map[key] = optionalCString(pair.value) ?? ""
        }
        return map
    }

    private static func restrictionMap(
        _ pointer: UnsafePointer<SpottyRestriction>?,
        count: Int
    ) -> [String: [String]] {
        guard count > 0, let pointer else { return [:] }
        var map: [String: [String]] = [:]
        for entry in UnsafeBufferPointer(start: pointer, count: count) {
            guard let key = optionalCString(entry.key) else { continue }
            map[key] = cStringList(entry.reasons, count: Int(entry.reason_count))
        }
        return map
    }

    private static func cStringList(
        _ pointer: UnsafePointer<UnsafePointer<CChar>?>?,
        count: Int
    ) -> [String] {
        guard count > 0, let pointer else { return [] }
        return UnsafeBufferPointer(start: pointer, count: count).map { optionalCString($0) ?? "" }
    }

    private static func takeOwnedString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { spotty_playback_free_string(pointer) }
        return String(cString: pointer)
    }

    private static func optionalCString(_ pointer: UnsafePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        return String(cString: pointer)
    }

    private static func withOptionalCString<R>(
        _ string: String?,
        _ body: (UnsafePointer<CChar>?) -> R
    ) -> R {
        guard let string else { return body(nil) }
        return string.withCString { body($0) }
    }

    static func next() -> Result { spotty_playback_next() }
    static func previous() -> Result { spotty_playback_previous() }
    static func seek(to milliseconds: UInt32) -> Result { spotty_playback_seek(milliseconds) }
    static func setShuffle(_ enabled: Bool) -> Result { spotty_playback_set_shuffle(enabled) }
    static func setRepeat(context: Bool) -> Result { spotty_playback_set_repeat_context(context) }
    static func setRepeatTrack(_ enabled: Bool) -> Result { spotty_playback_set_repeat_track(enabled) }
    static func positionMilliseconds() -> UInt32 { spotty_playback_get_position_ms() }

    /// Appends a track, episode, or whole context to the play queue.
    static func addToQueue(uri: String) -> Result {
        uri.withCString { spotty_playback_add_to_queue($0) }
    }

    /// Takes over playback from whatever Connect device is currently active.
    static func transferToLocal() -> Result { spotty_playback_transfer_to_local() }

    /// Hands playback to another Spotify Connect device.
    static func transferPlayback(to deviceID: String) -> Result {
        deviceID.withCString { spotty_playback_transfer_playback($0) }
    }

    /// The last queue the Connect cluster described, or nil before one has arrived.
    nonisolated static func queueSnapshot() -> RustQueueState? {
        guard let pointer = spotty_playback_get_queue_snapshot() else { return nil }
        defer { spotty_playback_free_queue_snapshot(pointer) }
        return queueState(from: UnsafePointer(pointer))
    }

    static func shutdown() -> Result { spotty_playback_shutdown() }
    static func cleanup() { spotty_playback_cleanup() }
    static func clearStreamingCredentials() { spotty_playback_clear_streaming_credentials() }

    /// Leaves Spotify Connect before system sleep, so this Mac disappears from other
    /// devices' pickers immediately. Unlike shutdown it does not block reconnection.
    nonisolated static func disconnect() -> Result { spotty_playback_disconnect() }

    /// Rebuilds the streaming session after macOS wakes.
    ///
    /// The backend captures the playing track and its position before tearing down, then its
    /// reconnection loop restores them. Returns 0 when a reconnection was triggered, 1 when one
    /// was already running, and 2 when no session existed — every outcome is fine to ignore,
    /// because the backend also self-reports disconnections on its own.
    nonisolated static func forceReconnect() -> Int32 {
        spotty_playback_force_reconnect()
    }

    /// A declined command is ordinary (for example Resume with no current context). Only
    /// backend lifecycle failures invalidate the connection and require reinitialization.
    static func requiresReconnect(after result: Result) -> Bool {
        result.rawValue == -2 || result.rawValue == -3
    }
}
