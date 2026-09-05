use crate::*;
use std::collections::HashMap;

pub(crate) fn send_playback_state(player_state: &PlayerState, is_active_device: bool) {
    debug!("send_playback_state called");

    // Log context URI - this is the "active playlist/album/artist" being played from
    let context_uri = &player_state.context_uri;
    if !context_uri.is_empty() {
        debug!("Context URI: {}", context_uri);
        update_current_context_uri(context_uri);
    }

    let Some(callback) = registered_callback(&CONTROL_CALLBACKS.playback_state) else {
        debug!("No playback state callback registered, skipping update");
        return;
    };

    // Extract track URI
    let track_uri = player_state
        .track
        .as_ref()
        .map(|t| t.uri.clone())
        .unwrap_or_default();

    // Extract playback options (shuffle, repeat)
    let options = player_state.options.as_ref();
    let shuffle = options.map(|o| o.shuffling_context).unwrap_or(false);
    let repeat_track = options.map(|o| o.repeating_track).unwrap_or(false);
    let repeat_context = options.map(|o| o.repeating_context).unwrap_or(false);
    update_playback_options(shuffle, repeat_track, repeat_context);

    // Forward protocol playing/paused bits. Swift projects transport presentation.
    let (stamp, observation) = stamped_snapshot(|stamp| {
        (
            stamp,
            PlaybackObservation {
                is_playing: player_state.is_playing,
                is_paused: player_state.is_paused,
                track_unavailable: false,
                track_uri,
                position_ms: player_state.position_as_of_timestamp,
                duration_ms: player_state.duration,
                shuffle,
                repeat_track,
                repeat_context,
                // This role bit was derived from the same cluster observation by the caller.
                // Keeping it inside the stamped payload means Swift never has to pair this
                // playback row with a separately arriving connection callback.
                is_active_device,
                timestamp_ms: player_state.timestamp,
            },
        )
    });

    debug!(
        "PlaybackState: playing={}, paused={}, position={}ms, duration={}ms, timestamp={}ms, shuffle={}, repeat_track={}, repeat_context={}",
        observation.is_playing,
        observation.is_paused,
        observation.position_ms,
        observation.duration_ms,
        observation.timestamp_ms,
        observation.shuffle,
        observation.repeat_track,
        observation.repeat_context
    );

    send_playback_snapshot(callback, stamp, &observation);
}

/// Send playback state update from local player events (Playing, Paused)
/// This is used when Spotty is the active device - state changes happen locally
/// and don't come through Mercury cluster updates.
pub(crate) struct LocalPlaybackStateNotification {
    callback: PlaybackSnapshotCallback,
    stamp: SnapshotStamp,
    observation: PlaybackObservation,
}

/// Captures a local playback callback while the caller still owns the event generation.
///
/// The payload and revision are copied before the generation mutation gate is released. Swift
/// must receive the generation that produced the event, even if a replacement session is
/// installed before the callback can run.
pub(crate) fn capture_local_playback_state(
    is_playing: bool,
    position_ms: u32,
    session_generation: u64,
) -> Option<LocalPlaybackStateNotification> {
    capture_local_playback_state_with_owner(
        is_playing,
        position_ms,
        Some(session_generation),
        false,
    )
}

/// Captures the one-shot local playback observation used for a current requested track's
/// unavailable event. The event pump has already applied its generation, request-identity, and
/// active-device checks before asking for this payload.
pub(crate) fn capture_local_playback_unavailable(
    position_ms: u32,
    session_generation: u64,
) -> Option<LocalPlaybackStateNotification> {
    capture_local_playback_state_with_owner(false, position_ms, Some(session_generation), true)
}

fn capture_local_playback_state_with_owner(
    is_playing: bool,
    position_ms: u32,
    session_generation: Option<u64>,
    track_unavailable: bool,
) -> Option<LocalPlaybackStateNotification> {
    debug!(
        "send_local_playback_state called: is_playing={}, position_ms={}",
        is_playing, position_ms
    );

    let callback = registered_callback(&CONTROL_CALLBACKS.playback_state)?;

    // Get track URI from local state
    let track_uri = CURRENT_TRACK_URI
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
        .unwrap_or_default();

    // Get duration from local state
    let duration_ms = CURRENT_DURATION_MS.load(Ordering::SeqCst);
    let (shuffle, repeat_track, repeat_context) = current_playback_options();
    let local_is_active_device = is_active_device();

    let build_observation = |stamp| {
        (
            stamp,
            PlaybackObservation {
                is_playing,
                // Local PlayerEvent has one bit; shape it as the protocol pair Swift already projects.
                is_paused: !is_playing,
                track_unavailable,
                track_uri,
                position_ms: position_ms as i64,
                duration_ms: duration_ms as i64,
                shuffle,
                repeat_track,
                repeat_context,
                is_active_device: local_is_active_device,
                timestamp_ms: current_timestamp_ms() as i64,
            },
        )
    };
    let (stamp, observation) = match session_generation {
        Some(session_generation) => {
            stamped_snapshot_for_generation(session_generation, build_observation)
        }
        None => stamped_snapshot(build_observation),
    };

    debug!(
        "Local PlaybackState: playing={}, paused={}, position={}ms, duration={}ms, shuffle={}, repeat_track={}, repeat_context={}",
        observation.is_playing,
        observation.is_paused,
        observation.position_ms,
        observation.duration_ms,
        observation.shuffle,
        observation.repeat_track,
        observation.repeat_context
    );

    Some(LocalPlaybackStateNotification {
        callback,
        stamp,
        observation,
    })
}

/// Delivers a previously captured local playback callback after all Rust state locks are gone.
pub(crate) fn deliver_local_playback_state(notification: LocalPlaybackStateNotification) {
    let LocalPlaybackStateNotification {
        callback,
        stamp,
        observation,
    } = notification;
    send_playback_snapshot(callback, stamp, &observation);
}

pub(crate) fn send_local_playback_state(is_playing: bool, position_ms: u32) {
    if let Some(notification) =
        capture_local_playback_state_with_owner(is_playing, position_ms, None, false)
    {
        deliver_local_playback_state(notification);
    }
}

/// Converts a Connect-state track into current-track identity for a queue snapshot.
///
/// Labels stay empty across this boundary: Swift projects presentation rows from
/// protocol tracks and resolves names from the catalog.
pub(crate) fn to_queue_item(track: &ProvidedTrack) -> QueueItem {
    QueueItem {
        uri: track.uri.clone(),
        provider: track.provider.clone(),
        uid: track.uid.clone(),
    }
}

pub(crate) fn to_protocol_track(track: &ProvidedTrack) -> ProtocolQueueTrack {
    ProtocolQueueTrack {
        uri: track.uri.clone(),
        uid: track.uid.clone(),
        provider: track.provider.clone(),
        metadata: track.metadata.clone(),
        removed: track.removed.clone(),
        blocked: track.blocked.clone(),
        restrictions: protocol_restrictions(track),
        album_uri: track.album_uri.clone(),
        disallow_reasons: track.disallow_reasons.clone(),
        artist_uri: track.artist_uri.clone(),
    }
}

fn protocol_restrictions(track: &ProvidedTrack) -> HashMap<String, Vec<String>> {
    let Some(restrictions) = track.restrictions.as_ref() else {
        return HashMap::new();
    };
    let mut map = HashMap::new();
    let fields: [(&str, &[String]); 25] = [
        (
            "disallow_pausing_reasons",
            &restrictions.disallow_pausing_reasons,
        ),
        (
            "disallow_resuming_reasons",
            &restrictions.disallow_resuming_reasons,
        ),
        (
            "disallow_seeking_reasons",
            &restrictions.disallow_seeking_reasons,
        ),
        (
            "disallow_peeking_prev_reasons",
            &restrictions.disallow_peeking_prev_reasons,
        ),
        (
            "disallow_peeking_next_reasons",
            &restrictions.disallow_peeking_next_reasons,
        ),
        (
            "disallow_skipping_prev_reasons",
            &restrictions.disallow_skipping_prev_reasons,
        ),
        (
            "disallow_skipping_next_reasons",
            &restrictions.disallow_skipping_next_reasons,
        ),
        (
            "disallow_toggling_repeat_context_reasons",
            &restrictions.disallow_toggling_repeat_context_reasons,
        ),
        (
            "disallow_toggling_repeat_track_reasons",
            &restrictions.disallow_toggling_repeat_track_reasons,
        ),
        (
            "disallow_toggling_shuffle_reasons",
            &restrictions.disallow_toggling_shuffle_reasons,
        ),
        (
            "disallow_set_queue_reasons",
            &restrictions.disallow_set_queue_reasons,
        ),
        (
            "disallow_interrupting_playback_reasons",
            &restrictions.disallow_interrupting_playback_reasons,
        ),
        (
            "disallow_transferring_playback_reasons",
            &restrictions.disallow_transferring_playback_reasons,
        ),
        (
            "disallow_remote_control_reasons",
            &restrictions.disallow_remote_control_reasons,
        ),
        (
            "disallow_inserting_into_next_tracks_reasons",
            &restrictions.disallow_inserting_into_next_tracks_reasons,
        ),
        (
            "disallow_inserting_into_context_tracks_reasons",
            &restrictions.disallow_inserting_into_context_tracks_reasons,
        ),
        (
            "disallow_reordering_in_next_tracks_reasons",
            &restrictions.disallow_reordering_in_next_tracks_reasons,
        ),
        (
            "disallow_reordering_in_context_tracks_reasons",
            &restrictions.disallow_reordering_in_context_tracks_reasons,
        ),
        (
            "disallow_removing_from_next_tracks_reasons",
            &restrictions.disallow_removing_from_next_tracks_reasons,
        ),
        (
            "disallow_removing_from_context_tracks_reasons",
            &restrictions.disallow_removing_from_context_tracks_reasons,
        ),
        (
            "disallow_updating_context_reasons",
            &restrictions.disallow_updating_context_reasons,
        ),
        (
            "disallow_playing_reasons",
            &restrictions.disallow_playing_reasons,
        ),
        (
            "disallow_stopping_reasons",
            &restrictions.disallow_stopping_reasons,
        ),
        (
            "disallow_add_to_queue_reasons",
            &restrictions.disallow_add_to_queue_reasons,
        ),
        (
            "disallow_setting_playback_speed_reasons",
            &restrictions.disallow_setting_playback_speed_reasons,
        ),
    ];
    for (key, values) in fields {
        if !values.is_empty() {
            map.insert(key.to_string(), values.to_vec());
        }
    }
    map
}

pub(crate) fn collect_protocol_tracks(tracks: &[ProvidedTrack]) -> Vec<ProtocolQueueTrack> {
    tracks.iter().map(to_protocol_track).collect()
}

pub(crate) fn queue_replacement_disallowed(player_state: &PlayerState) -> (bool, bool) {
    let Some(restrictions) = player_state.restrictions.as_ref() else {
        return (false, false);
    };
    (
        !restrictions.disallow_set_queue_reasons.is_empty(),
        !restrictions
            .disallow_removing_from_next_tracks_reasons
            .is_empty(),
    )
}

/// One Connect metadata pair. Pointers are valid only for the callback or until
/// `spotty_playback_free_queue_snapshot`. Null means missing; outbound empty strings and
/// strings containing an interior NUL are also delivered as null fields.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct SpottyStringPair {
    pub key: SpottyNullableCString,
    pub value: SpottyNullableCString,
}

/// One restriction key with its reason list. Pointers are valid only for the callback or until
/// `spotty_playback_free_queue_snapshot`. A null key or reason means that value is missing.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct SpottyRestriction {
    pub key: SpottyNullableCString,
    pub reasons: SpottyNullableCStringArray,
    pub reason_count: usize,
}

/// Unfiltered Connect queue row. String and nested pointers are valid only for the callback
/// or until `spotty_playback_free_queue_snapshot`. Null means missing; outbound empty strings
/// and strings containing an interior NUL are also delivered as null fields.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct SpottyProtocolQueueTrack {
    pub uri: SpottyNullableCString,
    pub uid: SpottyNullableCString,
    pub provider: SpottyNullableCString,
    pub metadata: SpottyNullableStringPairPointer,
    pub metadata_count: usize,
    pub removed: SpottyNullableCStringArray,
    pub removed_count: usize,
    pub blocked: SpottyNullableCStringArray,
    pub blocked_count: usize,
    pub restrictions: SpottyNullableRestrictionPointer,
    pub restriction_count: usize,
    pub album_uri: SpottyNullableCString,
    pub disallow_reasons: SpottyNullableCStringArray,
    pub disallow_reason_count: usize,
    pub artist_uri: SpottyNullableCString,
}

/// Queue observation. Pointers are valid only for the callback or until
/// `spotty_playback_free_queue_snapshot`. Null `next_tracks`/`prev_tracks` with count 0 is an
/// empty list. A missing current track is three null track fields. Outbound empty strings and
/// strings containing an interior NUL are delivered as null fields.
#[repr(C)]
pub struct SpottyQueueSnapshot {
    pub revision: u64,
    pub session_generation: u64,
    pub track_uri: SpottyNullableCString,
    pub track_provider: SpottyNullableCString,
    pub track_uid: SpottyNullableCString,
    pub next_tracks: SpottyNullableQueueTrackPointer,
    pub next_count: usize,
    pub prev_tracks: SpottyNullableQueueTrackPointer,
    pub prev_count: usize,
    pub queue_revision: SpottyNullableCString,
    pub disallow_set_queue: u8,
    pub disallow_removing_from_next_tracks: u8,
}

/// Callback function type for queue updates. Receives a typed snapshot; strings and nested
/// pointers are valid only for the callback invocation.
pub(crate) type QueueSnapshotCallback = extern "C" fn(*const SpottyQueueSnapshot);

struct CStringList {
    _values: Vec<Option<CString>>,
    pointers: Vec<*const c_char>,
}

impl CStringList {
    fn from_strings(items: &[String]) -> Self {
        let values: Vec<Option<CString>> = items
            .iter()
            .map(|item| optional_callback_c_string(Some(item)))
            .collect();
        let pointers = values
            .iter()
            .map(|value| {
                value
                    .as_ref()
                    .map(|c_string| c_string.as_ptr())
                    .unwrap_or(std::ptr::null())
            })
            .collect();
        Self {
            _values: values,
            pointers,
        }
    }

    fn as_ptr(&self) -> *const *const c_char {
        if self.pointers.is_empty() {
            std::ptr::null()
        } else {
            self.pointers.as_ptr()
        }
    }

    fn len(&self) -> usize {
        self.pointers.len()
    }
}

struct RestrictionBacking {
    key: Option<CString>,
    reasons: CStringList,
}

struct ProtocolTrackBacking {
    uri: Option<CString>,
    uid: Option<CString>,
    provider: Option<CString>,
    /// Keeps metadata CStrings alive for `metadata_rows` pointers.
    #[allow(dead_code)]
    metadata: Vec<(Option<CString>, Option<CString>)>,
    metadata_rows: Vec<SpottyStringPair>,
    removed: CStringList,
    blocked: CStringList,
    /// Keeps restriction keys and reason lists alive for `restriction_rows`.
    #[allow(dead_code)]
    restrictions: Vec<RestrictionBacking>,
    restriction_rows: Vec<SpottyRestriction>,
    album_uri: Option<CString>,
    disallow_reasons: CStringList,
    artist_uri: Option<CString>,
}

struct QueueSnapshotBacking {
    track_uri: Option<CString>,
    track_provider: Option<CString>,
    track_uid: Option<CString>,
    queue_revision: Option<CString>,
    next: Vec<ProtocolTrackBacking>,
    prev: Vec<ProtocolTrackBacking>,
    next_rows: Vec<SpottyProtocolQueueTrack>,
    prev_rows: Vec<SpottyProtocolQueueTrack>,
}

#[repr(C)]
struct OwnedQueueSnapshot {
    snapshot: SpottyQueueSnapshot,
    backing: QueueSnapshotBacking,
}

fn c_ptr(value: &Option<CString>) -> *const c_char {
    value
        .as_ref()
        .map(|c_string| c_string.as_ptr())
        .unwrap_or(std::ptr::null())
}

fn protocol_track_backing(track: &ProtocolQueueTrack) -> ProtocolTrackBacking {
    let metadata: Vec<(Option<CString>, Option<CString>)> = track
        .metadata
        .iter()
        .map(|(key, value)| {
            (
                optional_callback_c_string(Some(key)),
                optional_callback_c_string(Some(value)),
            )
        })
        .collect();
    let metadata_rows = metadata
        .iter()
        .map(|(key, value)| SpottyStringPair {
            key: c_ptr(key),
            value: c_ptr(value),
        })
        .collect();
    let restrictions: Vec<RestrictionBacking> = track
        .restrictions
        .iter()
        .map(|(key, reasons)| RestrictionBacking {
            key: optional_callback_c_string(Some(key)),
            reasons: CStringList::from_strings(reasons),
        })
        .collect();
    let restriction_rows = restrictions
        .iter()
        .map(|restriction| SpottyRestriction {
            key: c_ptr(&restriction.key),
            reasons: restriction.reasons.as_ptr(),
            reason_count: restriction.reasons.len(),
        })
        .collect();
    ProtocolTrackBacking {
        uri: optional_callback_c_string(Some(track.uri.as_str())),
        uid: optional_callback_c_string(Some(track.uid.as_str())),
        provider: optional_callback_c_string(Some(track.provider.as_str())),
        metadata,
        metadata_rows,
        removed: CStringList::from_strings(&track.removed),
        blocked: CStringList::from_strings(&track.blocked),
        restrictions,
        restriction_rows,
        album_uri: optional_callback_c_string(Some(track.album_uri.as_str())),
        disallow_reasons: CStringList::from_strings(&track.disallow_reasons),
        artist_uri: optional_callback_c_string(Some(track.artist_uri.as_str())),
    }
}

fn protocol_track_row(backing: &ProtocolTrackBacking) -> SpottyProtocolQueueTrack {
    SpottyProtocolQueueTrack {
        uri: c_ptr(&backing.uri),
        uid: c_ptr(&backing.uid),
        provider: c_ptr(&backing.provider),
        metadata: if backing.metadata_rows.is_empty() {
            std::ptr::null()
        } else {
            backing.metadata_rows.as_ptr()
        },
        metadata_count: backing.metadata_rows.len(),
        removed: backing.removed.as_ptr(),
        removed_count: backing.removed.len(),
        blocked: backing.blocked.as_ptr(),
        blocked_count: backing.blocked.len(),
        restrictions: if backing.restriction_rows.is_empty() {
            std::ptr::null()
        } else {
            backing.restriction_rows.as_ptr()
        },
        restriction_count: backing.restriction_rows.len(),
        album_uri: c_ptr(&backing.album_uri),
        disallow_reasons: backing.disallow_reasons.as_ptr(),
        disallow_reason_count: backing.disallow_reasons.len(),
        artist_uri: c_ptr(&backing.artist_uri),
    }
}

fn queue_snapshot_backing(state: &QueueState) -> QueueSnapshotBacking {
    let (track_uri, track_provider, track_uid) = match &state.track {
        Some(track) => (
            optional_callback_c_string(Some(track.uri.as_str())),
            optional_callback_c_string(Some(track.provider.as_str())),
            optional_callback_c_string(Some(track.uid.as_str())),
        ),
        None => (None, None, None),
    };
    let mut backing = QueueSnapshotBacking {
        track_uri,
        track_provider,
        track_uid,
        queue_revision: optional_callback_c_string(Some(state.queue_revision.as_str())),
        next: state
            .protocol_next_tracks
            .iter()
            .map(protocol_track_backing)
            .collect(),
        prev: state
            .protocol_prev_tracks
            .iter()
            .map(protocol_track_backing)
            .collect(),
        next_rows: Vec::new(),
        prev_rows: Vec::new(),
    };
    backing.next_rows = backing.next.iter().map(protocol_track_row).collect();
    backing.prev_rows = backing.prev.iter().map(protocol_track_row).collect();
    backing
}

fn queue_snapshot_from_backing(
    backing: &QueueSnapshotBacking,
    state: &QueueState,
) -> SpottyQueueSnapshot {
    SpottyQueueSnapshot {
        revision: state.revision,
        session_generation: state.session_generation,
        track_uri: c_ptr(&backing.track_uri),
        track_provider: c_ptr(&backing.track_provider),
        track_uid: c_ptr(&backing.track_uid),
        next_tracks: if backing.next_rows.is_empty() {
            std::ptr::null()
        } else {
            backing.next_rows.as_ptr()
        },
        next_count: backing.next_rows.len(),
        prev_tracks: if backing.prev_rows.is_empty() {
            std::ptr::null()
        } else {
            backing.prev_rows.as_ptr()
        },
        prev_count: backing.prev_rows.len(),
        queue_revision: c_ptr(&backing.queue_revision),
        disallow_set_queue: u8::from(state.disallow_set_queue),
        disallow_removing_from_next_tracks: u8::from(state.disallow_removing_from_next_tracks),
    }
}

pub(crate) fn send_queue_snapshot(callback: QueueSnapshotCallback, state: &QueueState) {
    let backing = queue_snapshot_backing(state);
    let snapshot = queue_snapshot_from_backing(&backing, state);
    callback(&snapshot);
}

pub(crate) fn alloc_queue_snapshot(state: &QueueState) -> *mut SpottyQueueSnapshot {
    let backing = queue_snapshot_backing(state);
    let mut owned = Box::new(OwnedQueueSnapshot {
        snapshot: SpottyQueueSnapshot {
            revision: 0,
            session_generation: 0,
            track_uri: std::ptr::null(),
            track_provider: std::ptr::null(),
            track_uid: std::ptr::null(),
            next_tracks: std::ptr::null(),
            next_count: 0,
            prev_tracks: std::ptr::null(),
            prev_count: 0,
            queue_revision: std::ptr::null(),
            disallow_set_queue: 0,
            disallow_removing_from_next_tracks: 0,
        },
        backing,
    });
    owned.snapshot = queue_snapshot_from_backing(&owned.backing, state);
    Box::into_raw(owned) as *mut SpottyQueueSnapshot
}

pub(crate) fn free_queue_snapshot(snapshot: *mut SpottyQueueSnapshot) {
    if snapshot.is_null() {
        return;
    }
    unsafe {
        drop(Box::from_raw(snapshot as *mut OwnedQueueSnapshot));
    }
}

/// Publishes the Connect queue as unfiltered protocol rows plus slim current-track identity.
///
/// Upcoming presentation (delimiter hiding, playable-track filtering) is Swift-owned
/// `QueueProtocolProjection`. This function must not drop delimiter or autoplay rows: they
/// are required for occurrence-safe `set_queue` replacement.
pub(crate) fn process_and_send_queue(player_state: PlayerState) {
    debug!("process_and_send_queue called");

    // Log context URI for queue processing too
    if !player_state.context_uri.is_empty() {
        debug!("Queue context URI: {}", player_state.context_uri);
        update_current_context_uri(&player_state.context_uri);
    }

    let protocol_next_tracks = collect_protocol_tracks(&player_state.next_tracks);
    let protocol_prev_tracks = collect_protocol_tracks(&player_state.prev_tracks);
    let queue_revision = player_state.queue_revision.clone();
    let (disallow_set_queue, disallow_removing_from_next_tracks) =
        queue_replacement_disallowed(&player_state);
    let current_track = player_state.track.into_option().and_then(|t| {
        debug!("current track[0] uri='{}' provider='{}'", t.uri, t.provider);
        if t.uri.starts_with("spotify:track:") {
            Some(to_queue_item(&t))
        } else {
            None
        }
    });

    debug!(
        "Queue protocol counts: current={}, next={}, prev={}",
        if current_track.is_some() { 1 } else { 0 },
        protocol_next_tracks.len(),
        protocol_prev_tracks.len()
    );

    let state = stamped_snapshot(|stamp| QueueState {
        revision: stamp.revision,
        session_generation: stamp.session_generation,
        track: current_track,
        protocol_next_tracks,
        protocol_prev_tracks,
        queue_revision,
        disallow_set_queue,
        disallow_removing_from_next_tracks,
    });

    // Cache even when Swift has not registered a callback yet. The getter replaces
    // `/me/player/queue` for bootstrap after a provisional empty SetQueue, so a cluster
    // tick that arrives before registration must still be recoverable. Send first, then
    // move into LAST_QUEUE so the callback does not run with that lock held.
    if let Some(callback) = registered_callback(&CONTROL_CALLBACKS.queue) {
        send_queue_snapshot(callback, &state);
    } else {
        debug!("No queue callback registered; caching snapshot for getter recovery");
    }
    *LAST_QUEUE.lock().unwrap_or_else(|e| e.into_inner()) = Some(state);
}

/// The last queue the cluster described, or null if no cluster update has arrived.
///
/// Cached independently of callback registration so a getter after late registration still
/// recovers a tick that arrived while Swift was not listening.
///
/// Replaces `/me/player/queue` and `/me/player` for Swift's bootstrap. Deliberately a snapshot
/// of what was already pushed rather than a fresh request: the cluster is the only source now,
/// so there is nothing newer to fetch, and a caller that gets null has genuinely not been told
/// anything yet rather than having been told there is nothing.
///
/// Pointers remain valid until `spotty_playback_free_queue_snapshot`.
#[no_mangle]
pub extern "C" fn spotty_playback_get_queue_snapshot() -> SpottyNullableQueueSnapshot {
    ffi_owned_ptr("spotty_playback_get_queue_snapshot", || {
        let snapshot = LAST_QUEUE.lock().unwrap_or_else(|e| e.into_inner()).clone();
        snapshot.map_or(std::ptr::null_mut(), |state| alloc_queue_snapshot(&state))
    })
}

/// Frees a queue snapshot allocated by `spotty_playback_get_queue_snapshot`. Tolerates a null
/// pointer.
#[no_mangle]
pub extern "C" fn spotty_playback_free_queue_snapshot(snapshot: SpottyNullableQueueSnapshot) {
    ffi_void("spotty_playback_free_queue_snapshot", || {
        free_queue_snapshot(snapshot);
    })
}
