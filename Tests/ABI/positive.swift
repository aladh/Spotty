func positiveImportContract() {
    // Required callback/snapshot pointer and required C-string argument.
    let registerConnection: (ConnectionStateCallback) -> Void =
        spotty_playback_register_connection_state_callback
    let connection: ConnectionStateCallback = { snapshot in
        let revision: UInt64 = snapshot.pointee.revision
        let device: UnsafePointer<CChar>? = snapshot.pointee.device_id
        let error: UnsafePointer<CChar>? = snapshot.pointee.last_error
        _ = (revision, device, error)
    }
    let registerQueue: (QueueCallback) -> Void =
        spotty_playback_register_queue_callback
    let registerPlayback: (PlaybackStateCallback) -> Void =
        spotty_playback_register_playback_state_callback
    let registerDevices: (DevicesCallback) -> Void =
        spotty_playback_register_devices_callback
    let registerAudioData: (AudioDataCallback) -> Void =
        spotty_playback_register_audio_data_callback
    let registerAudioControl: (AudioControlCallback) -> Void =
        spotty_playback_register_audio_control_callback
    let authorize: @convention(c) (UnsafePointer<CChar>) -> Int32 =
        spotty_playback_authorize_streaming
    let playURI: @convention(c) (UnsafePointer<CChar>) -> SpottyPlaybackResult =
        spotty_playback_play_uri

    // Optional C-string arguments/fields and typed open enums.
    let load:
        @convention(c) (
            UnsafePointer<CChar>,
            UnsafePointer<CChar>?,
            UInt32,
            Bool,
            UInt64
        ) -> SpottyPlaybackResult = spotty_playback_load
    let initWithOptionalToken:
        @convention(c) (
            UnsafePointer<CChar>?
        ) -> SpottyPlaybackResult = spotty_playback_init_player
    let initResult: SpottyPlaybackResult = initWithOptionalToken(nil)
    let raw: Int32 = initResult.rawValue
    let unknown: SpottyPlaybackResult? = SpottyPlaybackResult(rawValue: -99)

    let audioControl: AudioControlCallback = { event in
        let eventRaw: UInt8 = event.rawValue
        let unknownEvent: SpottyPlaybackAudioControlEvent? =
            SpottyPlaybackAudioControlEvent(rawValue: 123)
        _ = (eventRaw, unknownEvent)
    }
    let audioData: AudioDataCallback = { samples, sampleCount in
        let maybeSamples: UnsafePointer<Float>? = samples
        let count: Int = sampleCount
        _ = (maybeSamples, count)
    }

    // Optional mutable-string and snapshot returns/free arguments.
    let getContext: @convention(c) () -> UnsafeMutablePointer<CChar>? =
        spotty_playback_get_resume_context_uri
    let getTrack: @convention(c) () -> UnsafeMutablePointer<CChar>? =
        spotty_playback_get_resume_track_uri
    let getQueue: @convention(c) () -> UnsafeMutablePointer<SpottyQueueSnapshot>? =
        spotty_playback_get_queue_snapshot
    let freeString: @convention(c) (UnsafeMutablePointer<CChar>?) -> Void =
        spotty_playback_free_string
    let freeQueue: @convention(c) (UnsafeMutablePointer<SpottyQueueSnapshot>?) -> Void =
        spotty_playback_free_queue_snapshot

    // Nested optional struct-pointer and C-string-array fields.
    func inspectQueue(
        _ snapshot: SpottyQueueSnapshot,
        _ track: SpottyProtocolQueueTrack,
        _ pair: SpottyStringPair,
        _ restriction: SpottyRestriction,
        _ devices: SpottyDevicesSnapshot,
        _ playback: SpottyPlaybackSnapshot
    ) {
        let next: UnsafePointer<SpottyProtocolQueueTrack>? = snapshot.next_tracks
        let previous: UnsafePointer<SpottyProtocolQueueTrack>? = snapshot.prev_tracks
        let metadata: UnsafePointer<SpottyStringPair>? = track.metadata
        let restrictions: UnsafePointer<SpottyRestriction>? = track.restrictions
        let reasons: UnsafePointer<UnsafePointer<CChar>?>? = restriction.reasons
        let deviceRows: UnsafePointer<SpottyProtocolDevice>? = devices.devices
        let trackURI: UnsafePointer<CChar>? = track.uri
        let key: UnsafePointer<CChar>? = pair.key
        let active: UnsafePointer<CChar>? = devices.active_device_id
        let playbackTrack: UnsafePointer<CChar>? = playback.track_uri
        let playbackUnavailable: UInt8 = playback.track_unavailable
        _ = (
            next,
            previous,
            metadata,
            restrictions,
            reasons,
            deviceRows,
            trackURI,
            key,
            active,
            playbackTrack,
            playbackUnavailable
        )
    }

    let nullableString: UnsafeMutablePointer<CChar>? = nil
    let nullableQueue: UnsafeMutablePointer<SpottyQueueSnapshot>? = nil
    _ = (
        registerConnection,
        connection,
        registerQueue,
        registerPlayback,
        registerDevices,
        registerAudioData,
        registerAudioControl,
        authorize,
        playURI,
        load,
        initWithOptionalToken,
        audioControl,
        audioData,
        getContext,
        getTrack,
        getQueue,
        freeString,
        freeQueue,
        nullableString,
        nullableQueue,
        raw,
        unknown
    )
}
