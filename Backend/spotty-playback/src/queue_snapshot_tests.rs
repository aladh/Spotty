use super::*;

fn cstr_text(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        None
    } else {
        Some(unsafe { CStr::from_ptr(ptr) }.to_str().unwrap().to_string())
    }
}

fn string_list(ptr: *const *const c_char, count: usize) -> Vec<String> {
    if count == 0 || ptr.is_null() {
        return Vec::new();
    }
    unsafe { std::slice::from_raw_parts(ptr, count) }
        .iter()
        .map(|item| cstr_text(*item).unwrap_or_default())
        .collect()
}

pub(crate) fn fixture_queue_state() -> QueueState {
    let mut metadata = std::collections::HashMap::new();
    metadata.insert("is_queued".to_string(), "true".to_string());
    let mut restrictions = std::collections::HashMap::new();
    restrictions.insert(
        "disallow_resuming_reasons".to_string(),
        vec!["not_active_device".to_string()],
    );
    let mut prev_metadata = std::collections::HashMap::new();
    prev_metadata.insert(
        "context_uri".to_string(),
        "spotify:playlist:fixtureContext".to_string(),
    );
    QueueState {
        revision: 13,
        session_generation: 4,
        track: Some(QueueItem {
            uri: "spotify:track:fixtureNow".to_string(),
            provider: "context".to_string(),
            uid: "occ-now".to_string(),
        }),
        protocol_next_tracks: vec![
            ProtocolQueueTrack {
                uri: "spotify:track:fixtureDup".to_string(),
                uid: "occ-a".to_string(),
                provider: "queue".to_string(),
                metadata,
                removed: Vec::new(),
                blocked: Vec::new(),
                restrictions,
                album_uri: "spotify:album:fixtureAlbum".to_string(),
                disallow_reasons: vec!["not_active_device".to_string()],
                artist_uri: "spotify:artist:fixtureArtist".to_string(),
            },
            ProtocolQueueTrack {
                uri: "spotify:track:fixtureDup".to_string(),
                uid: "occ-b".to_string(),
                provider: "queue".to_string(),
                metadata: std::collections::HashMap::new(),
                removed: Vec::new(),
                blocked: Vec::new(),
                restrictions: std::collections::HashMap::new(),
                album_uri: String::new(),
                disallow_reasons: Vec::new(),
                artist_uri: String::new(),
            },
            ProtocolQueueTrack {
                uri: "spotify:delimiter".to_string(),
                uid: String::new(),
                provider: "delimiter".to_string(),
                metadata: std::collections::HashMap::new(),
                removed: Vec::new(),
                blocked: Vec::new(),
                restrictions: std::collections::HashMap::new(),
                album_uri: String::new(),
                disallow_reasons: Vec::new(),
                artist_uri: String::new(),
            },
        ],
        protocol_prev_tracks: vec![ProtocolQueueTrack {
            uri: "spotify:track:fixturePrev".to_string(),
            uid: "occ-prev".to_string(),
            provider: "context".to_string(),
            metadata: prev_metadata,
            removed: vec!["removed-reason".to_string()],
            blocked: vec!["blocked-reason".to_string()],
            restrictions: std::collections::HashMap::new(),
            album_uri: String::new(),
            disallow_reasons: Vec::new(),
            artist_uri: String::new(),
        }],
        queue_revision: "fixture-rev-1".to_string(),
        disallow_set_queue: true,
        disallow_removing_from_next_tracks: true,
    }
}

#[test]
fn queue_snapshot_callback_copies_nullable_fields() {
    extern "C" fn capture(snapshot: *const SpottyQueueSnapshot) {
        let snapshot = unsafe { &*snapshot };
        assert_eq!(snapshot.revision, 13);
        assert_eq!(snapshot.session_generation, 4);
        assert_eq!(
            cstr_text(snapshot.track_uri).as_deref(),
            Some("spotify:track:fixtureNow")
        );
        assert_eq!(
            cstr_text(snapshot.track_provider).as_deref(),
            Some("context")
        );
        assert_eq!(cstr_text(snapshot.track_uid).as_deref(), Some("occ-now"));
        assert_eq!(snapshot.next_count, 3);
        assert_eq!(snapshot.prev_count, 1);
        assert_eq!(
            cstr_text(snapshot.queue_revision).as_deref(),
            Some("fixture-rev-1")
        );
        assert_eq!(snapshot.disallow_set_queue, 1);
        assert_eq!(snapshot.disallow_removing_from_next_tracks, 1);
        let next = unsafe { std::slice::from_raw_parts(snapshot.next_tracks, snapshot.next_count) };
        assert_eq!(
            cstr_text(next[0].uri).as_deref(),
            Some("spotify:track:fixtureDup")
        );
        assert_eq!(cstr_text(next[0].uid).as_deref(), Some("occ-a"));
        assert_eq!(cstr_text(next[2].uri).as_deref(), Some("spotify:delimiter"));
        assert!(next[2].uid.is_null());
        assert_eq!(next[0].metadata_count, 1);
        let metadata = unsafe { &*next[0].metadata };
        assert_eq!(cstr_text(metadata.key).as_deref(), Some("is_queued"));
        assert_eq!(cstr_text(metadata.value).as_deref(), Some("true"));
        assert_eq!(next[0].restriction_count, 1);
        let restriction = unsafe { &*next[0].restrictions };
        assert_eq!(
            cstr_text(restriction.key).as_deref(),
            Some("disallow_resuming_reasons")
        );
        assert_eq!(
            string_list(restriction.reasons, restriction.reason_count),
            vec!["not_active_device".to_string()]
        );
        let prev = unsafe { std::slice::from_raw_parts(snapshot.prev_tracks, snapshot.prev_count) };
        assert_eq!(
            string_list(prev[0].removed, prev[0].removed_count),
            vec!["removed-reason".to_string()]
        );
        assert_eq!(
            string_list(prev[0].blocked, prev[0].blocked_count),
            vec!["blocked-reason".to_string()]
        );
    }

    send_queue_snapshot(capture, &fixture_queue_state());

    extern "C" fn capture_empty_and_nul(snapshot: *const SpottyQueueSnapshot) {
        let snapshot = unsafe { &*snapshot };
        assert!(snapshot.track_uri.is_null());
        assert!(snapshot.track_provider.is_null());
        assert!(snapshot.track_uid.is_null());
        assert!(snapshot.queue_revision.is_null());
        assert_eq!(snapshot.next_count, 1);
        let next = unsafe { std::slice::from_raw_parts(snapshot.next_tracks, snapshot.next_count) };
        assert!(next[0].uri.is_null());
        assert!(next[0].provider.is_null());
        assert!(next[0].album_uri.is_null());
    }

    send_queue_snapshot(
        capture_empty_and_nul,
        &QueueState {
            revision: 1,
            session_generation: 1,
            track: None,
            protocol_next_tracks: vec![ProtocolQueueTrack {
                uri: String::new(),
                uid: "kept".to_string(),
                provider: "bad\0provider".to_string(),
                metadata: std::collections::HashMap::new(),
                removed: Vec::new(),
                blocked: Vec::new(),
                restrictions: std::collections::HashMap::new(),
                album_uri: String::new(),
                disallow_reasons: Vec::new(),
                artist_uri: String::new(),
            }],
            protocol_prev_tracks: Vec::new(),
            queue_revision: String::new(),
            disallow_set_queue: false,
            disallow_removing_from_next_tracks: false,
        },
    );
}

#[test]
fn queue_snapshot_getter_copies_then_frees() {
    let _guard = lock_lifecycle_test_globals();
    {
        *LAST_QUEUE.lock().unwrap_or_else(|e| e.into_inner()) = Some(fixture_queue_state());
    }
    let pointer = spotty_playback_get_queue_snapshot();
    assert!(!pointer.is_null());
    {
        let snapshot = unsafe { &*pointer };
        assert_eq!(snapshot.revision, 13);
        assert_eq!(
            cstr_text(snapshot.track_uri).as_deref(),
            Some("spotify:track:fixtureNow")
        );
        assert_eq!(snapshot.next_count, 3);
    }
    spotty_playback_free_queue_snapshot(pointer);
    spotty_playback_free_queue_snapshot(std::ptr::null_mut());
    {
        *LAST_QUEUE.lock().unwrap_or_else(|e| e.into_inner()) = None;
    }
    assert!(spotty_playback_get_queue_snapshot().is_null());
}

#[test]
fn process_and_send_queue_caches_snapshot_without_a_callback() {
    let _guard = lock_lifecycle_test_globals();
    *CONTROL_CALLBACKS
        .queue
        .lock()
        .unwrap_or_else(|e| e.into_inner()) = None;
    *LAST_QUEUE.lock().unwrap_or_else(|e| e.into_inner()) = None;

    let mut player = PlayerState::new();
    let track = player.track.mut_or_insert_default();
    track.uri = "spotify:track:cachedNow".to_string();
    track.provider = "context".to_string();
    track.uid = "occ-now".to_string();
    player.queue_revision = "cached-rev".to_string();
    player.next_tracks.push(ProvidedTrack {
        uri: "spotify:track:next".to_string(),
        uid: "q0".to_string(),
        provider: "queue".to_string(),
        ..Default::default()
    });

    process_and_send_queue(player);

    let pointer = spotty_playback_get_queue_snapshot();
    assert!(!pointer.is_null());
    {
        let snapshot = unsafe { &*pointer };
        assert_eq!(
            cstr_text(snapshot.track_uri).as_deref(),
            Some("spotify:track:cachedNow")
        );
        assert_eq!(snapshot.next_count, 1);
        assert_eq!(
            cstr_text(snapshot.queue_revision).as_deref(),
            Some("cached-rev")
        );
    }
    spotty_playback_free_queue_snapshot(pointer);
    *LAST_QUEUE.lock().unwrap_or_else(|e| e.into_inner()) = None;
}
