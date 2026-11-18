use super::*;

fn provided_track(uri: &str, provider: &str) -> ProvidedTrack {
    provided_track_with_uid(uri, provider, "")
}

fn provided_track_with_uid(uri: &str, provider: &str, uid: &str) -> ProvidedTrack {
    ProvidedTrack {
        uri: uri.to_string(),
        provider: provider.to_string(),
        uid: uid.to_string(),
        ..Default::default()
    }
}

fn provided_track_with_metadata(
    uri: &str,
    provider: &str,
    uid: &str,
    sentinel_key: &str,
    sentinel_value: &str,
) -> ProvidedTrack {
    let mut track = provided_track_with_uid(uri, provider, uid);
    track
        .metadata
        .insert(sentinel_key.to_string(), sentinel_value.to_string());
    track.album_uri = "spotify:album:fixture".to_string();
    track.artist_uri = "spotify:artist:fixture".to_string();
    track
}

#[test]
fn queue_conversion_preserves_identity_and_provider() {
    let item = to_protocol_track(&provided_track_with_uid(
        "spotify:track:abc",
        "queue",
        "occ-1",
    ));

    assert_eq!(item.uri, "spotify:track:abc");
    assert_eq!(item.provider, "queue");
    assert_eq!(item.uid, "occ-1");
}

#[test]
fn protocol_queue_tracks_keep_delimiter_episodes_and_autoplay() {
    let tracks = vec![
        provided_track("spotify:episode:ignored", "context"),
        provided_track("spotify:track:first", "queue"),
        provided_track("spotify:delimiter", "delimiter"),
        provided_track("spotify:track:autoplay-hidden", "autoplay"),
    ];
    let protocol = collect_protocol_tracks(&tracks);
    assert_eq!(protocol.len(), 4);
    assert_eq!(protocol[0].uri, "spotify:episode:ignored");
    assert_eq!(protocol[1].uri, "spotify:track:first");
    assert_eq!(protocol[2].uri, "spotify:delimiter");
    assert_eq!(protocol[3].provider, "autoplay");
}

#[test]
fn protocol_queue_tracks_keep_delimiter_and_occurrence_uids() {
    let tracks = vec![
        provided_track_with_uid("spotify:track:first", "queue", "q0"),
        provided_track_with_uid("spotify:delimiter", "delimiter", ""),
        provided_track_with_uid("spotify:track:autoplay-hidden", "autoplay", "a0"),
    ];
    let protocol = collect_protocol_tracks(&tracks);
    assert_eq!(protocol.len(), 3);
    assert_eq!(protocol[0].uid, "q0");
    assert_eq!(protocol[1].uri, "spotify:delimiter");
    assert_eq!(protocol[2].provider, "autoplay");
}

#[test]
fn protocol_queue_tracks_preserve_incoming_provided_track_metadata() {
    let tracks = vec![
        provided_track_with_metadata(
            "spotify:track:first",
            "queue",
            "q0",
            "spotty.sentinel",
            "keep-me",
        ),
        provided_track_with_uid("spotify:delimiter", "delimiter", ""),
        provided_track_with_metadata(
            "spotify:track:autoplay-hidden",
            "autoplay",
            "a0",
            "spotty.sentinel",
            "autoplay-keep",
        ),
    ];
    let mut prev = provided_track_with_metadata(
        "spotify:track:prev",
        "context",
        "p0",
        "spotty.sentinel",
        "prev-keep",
    );
    prev.removed = vec!["removed-reason".to_string()];
    prev.blocked = vec!["blocked-reason".to_string()];
    prev.disallow_reasons = vec!["disallow-reason".to_string()];

    let next = collect_protocol_tracks(&tracks);
    assert_eq!(
        next[0].metadata.get("spotty.sentinel").map(String::as_str),
        Some("keep-me")
    );
    assert_eq!(next[0].album_uri, "spotify:album:fixture");
    assert_eq!(next[0].artist_uri, "spotify:artist:fixture");
    assert_eq!(next[1].uri, "spotify:delimiter");
    assert_eq!(
        next[2].metadata.get("spotty.sentinel").map(String::as_str),
        Some("autoplay-keep")
    );

    let prev_protocol = to_protocol_track(&prev);
    assert_eq!(
        prev_protocol
            .metadata
            .get("spotty.sentinel")
            .map(String::as_str),
        Some("prev-keep")
    );
    assert_eq!(prev_protocol.removed, vec!["removed-reason".to_string()]);
    assert_eq!(prev_protocol.blocked, vec!["blocked-reason".to_string()]);
    assert_eq!(
        prev_protocol.disallow_reasons,
        vec!["disallow-reason".to_string()]
    );
}

#[test]
fn queue_replacement_reads_player_restrictions() {
    let mut allowed = PlayerState::new();
    assert_eq!(queue_replacement_disallowed(&allowed), (false, false));

    allowed
        .restrictions
        .mut_or_insert_default()
        .disallow_set_queue_reasons = vec!["not_allowed".to_string()];
    assert_eq!(queue_replacement_disallowed(&allowed), (true, false));

    let mut removing = PlayerState::new();
    removing
        .restrictions
        .mut_or_insert_default()
        .disallow_removing_from_next_tracks_reasons = vec!["restricted".to_string()];
    assert_eq!(queue_replacement_disallowed(&removing), (false, true));
}
