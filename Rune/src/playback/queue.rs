use crate::playback::*;
use std::collections::HashMap;

fn playback_options(player_state: &PlayerState) -> (bool, bool, bool) {
    let options = player_state.options.as_ref();
    (
        options.map(|o| o.shuffling_context).unwrap_or(false),
        options.map(|o| o.repeating_track).unwrap_or(false),
        options.map(|o| o.repeating_context).unwrap_or(false),
    )
}

/// Builds protocol playback facts without assigning a callback revision. The aggregate Connect
/// publisher owns that revision so all fields are delivered as one cluster observation.
pub(crate) fn playback_observation_from_player_state(
    player_state: &PlayerState,
    is_active_device: bool,
) -> PlaybackObservation {
    let track_uri = player_state
        .track
        .as_ref()
        .map(|track| track.uri.clone())
        .unwrap_or_default();
    let (shuffle, repeat_track, repeat_context) = playback_options(player_state);
    PlaybackObservation {
        is_playing: player_state.is_playing,
        is_paused: player_state.is_paused,
        track_unavailable: false,
        audio_key_refused: false,
        track_uri,
        context_uri: Some(player_state.context_uri.clone()),
        position_ms: player_state.position_as_of_timestamp,
        duration_ms: player_state.duration,
        shuffle,
        repeat_track,
        repeat_context,
        is_active_device,
        timestamp_ms: player_state.timestamp,
    }
}

/// Copies local player facts under their originating generation before delivery.
pub(crate) fn capture_local_playback_state(
    is_playing: bool,
    position_ms: u32,
    session_generation: u64,
) -> client::Playback {
    capture_local_playback(is_playing, position_ms, session_generation, false, false)
}

/// Captures the one-shot failure for the current requested track.
pub(crate) fn capture_local_playback_unavailable(
    position_ms: u32,
    session_generation: u64,
    audio_key_refused: bool,
) -> client::Playback {
    capture_local_playback(
        false,
        position_ms,
        session_generation,
        true,
        audio_key_refused,
    )
}

fn capture_local_playback(
    playing: bool,
    position_ms: u32,
    generation: u64,
    unavailable: bool,
    rejected: bool,
) -> client::Playback {
    stamped_snapshot_for_generation(generation, |stamp| {
        let track = CURRENT_TRACK_URI
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
            .unwrap_or_default();
        let (shuffle, repeat_track, repeat_context) = current_playback_options();
        let duration_ms = if track.is_empty() {
            0
        } else {
            CURRENT_DURATION_MS.load(Ordering::SeqCst)
        };
        client::Playback {
            sequence: stamp.revision,
            generation: stamp.session_generation,
            position_ms,
            duration_ms,
            timestamp_ms: current_timestamp_ms() as i64,
            playing,
            unavailable,
            rejected,
            shuffle,
            repeat_track,
            repeat_context,
            local: is_active_device(),
            track,
            // Local timing events never supply protocol context.
            context: None,
        }
    })
}

pub(crate) fn deliver_local_playback_state(notification: client::Playback) {
    client::publish_observation(client::Observation::Playback(notification));
}

pub(crate) fn to_protocol_track(track: &ProvidedTrack) -> client::QueueTrack {
    client::QueueTrack {
        uri: track.uri.clone(),
        uid: track.uid.clone(),
        provider: track.provider.clone(),
        metadata: track
            .metadata
            .iter()
            .map(|(key, value)| (key.clone(), value.clone()))
            .collect(),
        removed: track.removed.clone(),
        blocked: track.blocked.clone(),
        restrictions: protocol_restrictions(track).into_iter().collect(),
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

pub(crate) fn collect_protocol_tracks(tracks: &[ProvidedTrack]) -> Vec<client::QueueTrack> {
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
            .is_empty()
            || !restrictions
                .disallow_removing_from_context_tracks_reasons
                .is_empty(),
    )
}

/// Copies protocol order, occurrences, and restrictions into the aggregate observation.
pub(crate) fn queue_from_player_state(player: &PlayerState, stamp: SnapshotStamp) -> client::Queue {
    let (disallow_set_queue, disallow_removing) = queue_replacement_disallowed(player);
    client::Queue {
        sequence: stamp.revision,
        generation: stamp.session_generation,
        revision: (!player.queue_revision.is_empty()).then(|| player.queue_revision.clone()),
        track: player
            .track
            .as_ref()
            .filter(|track| track.uri.starts_with("spotify:track:"))
            .map(|track| track.uri.clone())
            .unwrap_or_default(),
        context: player.context_uri.clone(),
        next: collect_protocol_tracks(&player.next_tracks),
        previous: collect_protocol_tracks(&player.prev_tracks),
        removal_disallowed: disallow_set_queue || disallow_removing,
    }
}

/// Playback facts before the app projects the protocol transport flags.
pub(crate) struct PlaybackObservation {
    pub is_playing: bool,
    pub is_paused: bool,
    /// True only for the one local snapshot that reports the current requested track's
    /// unavailable event. Protocol snapshots and ordinary local transport updates keep this
    /// false.
    pub track_unavailable: bool,
    pub audio_key_refused: bool,
    pub track_uri: String,
    pub context_uri: Option<String>,
    pub position_ms: i64,
    pub duration_ms: i64,
    pub shuffle: bool,
    pub repeat_track: bool,
    pub repeat_context: bool,
    pub is_active_device: bool,
    pub timestamp_ms: i64,
}
