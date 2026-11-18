use super::*;

#[test]
fn playback_urls_preserve_spotify_resources_and_ignore_query_and_fragment() {
    const ID: &str = "0000000000000000000001";
    for kind in ["track", "album", "artist", "playlist", "episode", "show"] {
        let expected = format!("spotify:{kind}:{ID}");
        for url in [
            format!("https://open.spotify.com/{kind}/{ID}"),
            format!("HTTPS://open.spotify.com/{kind}/{ID}"),
            format!("http://open.spotify.com/{kind}/{ID}?si=shared"),
            format!("https://OPEN.SPOTIFY.COM/intl-de/{kind}/{ID}#details"),
            format!("https://open.spotify.com/intl-en/{kind}/{ID}?si=shared#details"),
            format!("https://open.spotify.com/intl-pt-BR/{kind}/{ID}?next=/ignored/path#details"),
            format!("https://open.spotify.com/{kind}/{ID}/"),
            format!("https://open.spotify.com/intl-en/{kind}/{ID}/?si=shared#details"),
        ] {
            assert_eq!(
                url_to_uri(&url).as_deref(),
                Some(expected.as_str()),
                "{url}"
            );
        }
    }
}

#[test]
fn playback_urls_leave_protocol_uri_forms_to_librespot() {
    for uri in [
        "spotify:track:0000000000000000000001",
        "spotify:album:0000000000000000000001",
        "spotify:user:alice:playlist:0000000000000000000001",
        "spotify:user:alice:collection",
        "spotify:user:alice:collection:artist:0000000000000000000001",
        "spotify:search:never+gonna",
        "spotify:local:artist:album:title:180",
        "spotify:genre:pop",
    ] {
        assert_eq!(url_to_uri(uri).as_deref(), Some(uri));
        let resource = uri.strip_prefix("spotify:").unwrap();
        assert_eq!(
            url_to_uri(&format!("SpOtIfY:{resource}")).as_deref(),
            Some(uri)
        );
    }
}

const INVALID_PLAYBACK_URLS: &[&str] = &[
    "",
    "not a Spotify URI",
    "https://notopen.spotify.com/track/0000000000000000000001",
    "https://open.spotify.com.evil.example/track/0000000000000000000001",
    "https://example.com/open.spotify.com/track/0000000000000000000001",
    "https://example.com/?next=https://open.spotify.com/track/0000000000000000000001",
    "https://example.com/#https://open.spotify.com/track/0000000000000000000001",
    "https://user@open.spotify.com/track/0000000000000000000001",
    "https://open.spotify.com:443/track/0000000000000000000001",
    "file://open.spotify.com/track/0000000000000000000001",
    "//open.spotify.com/track/0000000000000000000001",
    "https://open.spotify.com/track/0000000000000000000001/extra",
    "https://open.spotify.com/track/0000000000000000000001//",
    "https://open.spotify.com/track/0000000000000000000001/extra/",
    "https://open.spotify.com/track/intl-de/0000000000000000000001",
    "https://open.spotify.com/intl-de/intl-fr/track/0000000000000000000001",
    "https://open.spotify.com/intl-/track/0000000000000000000001",
    "https://open.spotify.com/intl-de%2F/track/0000000000000000000001",
    "https://open.spotify.com/intl-de--DE/track/0000000000000000000001",
    "https://open.spotify.com//track/0000000000000000000001",
    "https://open.spotify.com/track//0000000000000000000001",
    "https://open.spotify.com/track",
    "https://open.spotify.com/track/",
    "https://open.spotify.com/track/invalid-id",
    "https://open.spotify.com/track/short",
    "https://open.spotify.com/track/0000000000000000000001%2Fextra",
    "https://open.spotify.com/track/0000000000000000000001:extra",
    "https://open.spotify.com/foobar/0000000000000000000001",
    "https://open.spotify.com/genre/pop",
];

#[test]
fn playback_urls_reject_spoofed_hosts_and_malformed_resource_paths() {
    for input in INVALID_PLAYBACK_URLS {
        assert_eq!(url_to_uri(input), None, "{input}");
    }
}

#[test]
fn playback_urls_are_rejected_before_session_admission() {
    let _guard = lock_global_state();
    let previous = with_connection(std::mem::take);
    let results: Vec<_> = INVALID_PLAYBACK_URLS
        .iter()
        .map(|input| client::command(client::generation(), client::Command::Play(input)))
        .collect();
    let valid = "https://open.spotify.com/track/0000000000000000000001";
    let valid_result = client::command(client::generation(), client::Command::Play(valid));
    let activated = is_active_device();
    with_connection(|connection| *connection = previous);

    assert_eq!(valid_result, Err(client::CommandError::NotConnected));
    assert!(!activated);
    for (input, result) in INVALID_PLAYBACK_URLS.iter().zip(results) {
        assert_eq!(result, Err(client::CommandError::Failed), "{input}");
    }
}

#[test]
fn connect_config_advertises_configured_device_name() {
    let name = "Studio Mac (Spotty)";
    assert_eq!(create_connect_config(name).name, name);
}

#[test]
fn connect_config_uses_the_configured_device_name() {
    let expected = "Studio Mac (Spotty)";
    set_connect_device_name(expected);

    let configured = configured_connect_device_name().expect("device name was stored");
    assert_eq!(create_connect_config(&configured).name, expected);
}

// Recovery must start from transport evidence, not from Connect activity. These cover
// the distinction that P0.1 was about: librespot emits the same deactivation event for
// an ordinary handoff and for an unexpected Spirc shutdown.

#[test]
fn deactivation_alone_does_not_recover() {
    // Another device took over. The session is fine — do not reconnect.
    assert!(!should_recover_after_deactivation(false, false));
}

#[test]
fn deactivation_with_dead_session_recovers() {
    // librespot calls handle_disconnect on unexpected Spirc shutdown; the cluster
    // listener can miss that while the dealer stream is still open.
    assert!(should_recover_after_deactivation(true, false));
}

#[test]
fn deactivation_during_teardown_never_recovers() {
    // Sleep and shutdown disconnect on purpose; recovering would fight them.
    assert!(!should_recover_after_deactivation(true, true));
    assert!(!should_recover_after_deactivation(false, true));
}

// A listener or loop belonging to a replaced session must not act. Before the rewrite
// this could not be expressed: one event listener survived across sessions, so its
// generation was rewritten in place and the staleness check compared two values that
// were always equal.

#[test]
fn a_superseded_listener_is_rejected() {
    // The replacement is installed while the old listener is still draining.
    assert!(!listener_may_act(3, 4));
}

#[test]
fn the_current_listener_acts() {
    assert!(listener_may_act(4, 4));
}

#[test]
fn a_reconnect_loop_abandons_after_its_generation_moves() {
    // A restart landed while the loop slept between attempts; rebuilding now would
    // replace a healthy new session with one built from a stale token.
    assert!(!reconnect_may_proceed(2, 3, false));
}

#[test]
fn a_reconnect_loop_abandons_during_teardown() {
    assert!(!reconnect_may_proceed(2, 2, true));
}

#[test]
fn a_reconnect_loop_does_not_abandon_because_of_its_own_rebuild() {
    // Regression: each attempt calls build_player_async, which bumps the generation
    // before it can fail. Comparing against the value captured at loop start made the
    // loop read its own rebuild as a foreign supersede and give up after one attempt,
    // killing the remaining nine backoff retries — and with the Player already torn
    // down by the preceding cleanup, playback stayed dead for the whole outage.
    let mut recovering = 2;
    let after_own_failed_attempt = 3; // build_player_async bumped it, then errored
    assert!(!reconnect_may_proceed(
        recovering,
        after_own_failed_attempt,
        false
    ));

    // Adopting the generation our own attempt produced is what keeps the loop alive.
    recovering = after_own_failed_attempt;
    assert!(reconnect_may_proceed(
        recovering,
        after_own_failed_attempt,
        false
    ));
}

#[test]
fn a_reconnect_loop_still_abandons_on_a_foreign_rebuild() {
    // Adopting our own bump must not blind the loop to someone else's.
    let recovering = 3; // adopted after our own attempt
    assert!(!reconnect_may_proceed(recovering, 4, false));
}

#[test]
fn a_reconnect_loop_proceeds_for_its_own_generation() {
    assert!(reconnect_may_proceed(2, 2, false));
}

// The periodic health check is the only thing watching while Spotty is idle, so its
// trigger has to cover more than a session that reports itself invalid.

// Only local playback is rehydrated, and the intent has to be captured before the
// disconnect handling clears it.

#[test]
fn local_playback_is_resumed() {
    assert!(
        RecoveryIntent {
            was_playing: true,
            was_active: true
        }
        .should_resume()
    );
}

#[test]
fn remote_playback_is_left_alone() {
    // Another device is still playing; taking over would steal it from the user.
    assert!(
        !RecoveryIntent {
            was_playing: true,
            was_active: false
        }
        .should_resume()
    );
}

#[test]
fn nothing_is_resumed_without_also_being_activated() {
    // Rehydration loads require an already-activated device: Spirc discards `Load`
    // while inactive. `build_player_async` activates from `activate_after_connect`, a
    // separate argument from `resume_after_connect` — so pin the implication that keeps
    // the two consistent rather than leaving it to whoever next edits the call.
    for was_playing in [false, true] {
        for was_active in [false, true] {
            let intent = RecoveryIntent {
                was_playing,
                was_active,
            };
            assert!(!intent.should_resume() || intent.was_active);
        }
    }
}

#[test]
fn a_paused_local_player_is_not_resumed() {
    assert!(
        !RecoveryIntent {
            was_playing: false,
            was_active: true
        }
        .should_resume()
    );
}

#[test]
fn a_rehydration_load_runs_only_for_the_current_generation_with_an_open_window() {
    let _guard = lock_global_state();
    let previous_generation = SESSION_GENERATION.load(Ordering::SeqCst);
    let previous_connection = with_connection(std::mem::take);
    let previous_resume = with_engine(|engine| std::mem::take(&mut engine.observed_resume));
    let spirc = librespot_connect::SpottyTransportFixture::closed_handle();
    let target = || {
        (
            ResumeLoadTarget::Track {
                uri: "spotify:track:fixture".into(),
                position_ms: 10,
            },
            selection_load_policy::SelectionLoadPolicy::capture(
                selection_load_policy::SelectionOrder::Supplied,
            ),
        )
    };

    set_session_generation_for_test(0);
    with_connection(|c| c.resume_pending = true);
    assert!(!rehydration_load_is_current(0));
    assert_eq!(
        queue_rehydration(0, &spirc, target()),
        Err(CommandError::NotConnected)
    );

    set_session_generation_for_test(11);
    with_connection(|c| c.resume_pending = false);
    assert_eq!(
        queue_rehydration(11, &spirc, target()),
        Err(CommandError::NotConnected)
    );
    with_connection(|c| c.resume_pending = true);
    assert_eq!(
        queue_rehydration(11, &spirc, target()),
        Err(CommandError::NotConnected)
    );

    store_active_device(true);
    assert!(rehydration_load_is_current(11));
    assert_eq!(
        queue_rehydration(11, &spirc, target()),
        Err(CommandError::NeedsReinitialization)
    );

    set_session_generation_for_test(12);
    assert!(!rehydration_load_is_current(11));
    assert_eq!(
        queue_rehydration(11, &spirc, target()),
        Err(CommandError::NotConnected)
    );

    set_session_generation_for_test(previous_generation);
    with_connection(|connection| *connection = previous_connection);
    with_engine(|engine| engine.observed_resume = previous_resume);
}

#[test]
fn resume_capture_uses_nonempty_sticky_identity_and_the_saved_position() {
    let _guard = lock_global_state();
    let old_context = CURRENT_CONTEXT_URI.lock().unwrap().replace(String::new());
    let old_track = CURRENT_TRACK_URI.lock().unwrap().replace(String::new());
    let old_position = RESUME_POSITION_MS.swap(152_000, Ordering::SeqCst);
    assert!(capture_resume_targets().is_empty());

    *CURRENT_TRACK_URI.lock().unwrap() = Some("spotify:track:one".into());
    *CURRENT_CONTEXT_URI.lock().unwrap() = Some("spotify:playlist:ctx".into());
    let targets: Vec<_> = capture_resume_targets()
        .into_iter()
        .map(|(target, _)| target)
        .collect();
    assert_eq!(
        targets,
        [
            ResumeLoadTarget::Context {
                uri: "spotify:playlist:ctx".into(),
                track_hint: Some("spotify:track:one".into()),
                position_ms: 152_000,
            },
            ResumeLoadTarget::Track {
                uri: "spotify:track:one".into(),
                position_ms: 152_000
            },
        ]
    );
    *CURRENT_CONTEXT_URI.lock().unwrap() = old_context;
    *CURRENT_TRACK_URI.lock().unwrap() = old_track;
    RESUME_POSITION_MS.store(old_position, Ordering::SeqCst);
}

#[test]
fn rehydration_wait_requires_playback_evidence_from_the_current_generation() {
    let _guard = lock_global_state();
    let previous_generation = set_session_generation_for_test(7);
    let previous_pending = with_connection(|c| std::mem::replace(&mut c.resume_pending, true));
    let previous_playing = playing_event_stamp();
    let was_playing = engine_is_playing();

    for generation in [6, 7] {
        publish_playing_event(generation);
        assert_eq!(
            RUNTIME.block_on(wait_for_rehydration(
                7,
                previous_playing.sequence,
                Duration::ZERO
            )),
            RehydrationOutcome::TimedOut,
            "a Playing event needs current protocol evidence for the requested load"
        );
    }
    set_session_generation_for_test(previous_generation);
    replace_playing_event_stamp_for_test(previous_playing);
    set_engine_playing_for_test(was_playing);
    with_connection(|connection| connection.resume_pending = previous_pending);
}

#[test]
fn connection_state_starts_without_an_open_rehydration_window() {
    assert!(!ConnectionState::default().resume_pending);
}

#[test]
fn health_check_recovers_a_dead_session() {
    assert!(health_check_should_recover(true, false, false, false));
}

#[test]
fn health_check_recovers_a_session_that_never_connected() {
    // Regression: Session::is_invalid is only set by shutdown(), so a session left
    // behind by a failed init reports valid forever. Before this, nothing retried —
    // the original app watchdog used to paper over it by rebuilding every 120s, and removing
    // that watchdog exposed the gap at both startup and after a failed rebuild.
    assert!(health_check_should_recover(false, false, false, false));
}

#[test]
fn health_check_leaves_a_healthy_session_alone() {
    assert!(!health_check_should_recover(false, true, false, false));
}

#[test]
fn health_check_defers_to_a_running_reconnect() {
    // The loop is what fixes this; firing alongside it would just re-publish a
    // disconnected snapshot once a minute.
    assert!(!health_check_should_recover(true, false, true, false));
}

#[test]
fn health_check_stays_out_of_a_teardown() {
    assert!(!health_check_should_recover(true, false, false, true));
}

#[test]
fn only_the_current_cluster_listener_recovers() {
    assert!(should_recover_after_cluster_end(7, 7, false));
    // An older listener ending is the expected result of its session being replaced.
    assert!(!should_recover_after_cluster_end(6, 7, false));
    assert!(!should_recover_after_cluster_end(7, 7, true));
}

// Active-device state is derived from the cluster rather than inferred from whichever
// command ran last (P1.3).

#[test]
fn cluster_naming_us_makes_us_active() {
    assert!(is_active_in_cluster(
        "spotty_playback_1234",
        Some("spotty_playback_1234")
    ));
}

#[test]
fn cluster_naming_another_device_makes_us_inactive() {
    assert!(!is_active_in_cluster(
        "phone-abc",
        Some("spotty_playback_1234")
    ));
}

#[test]
fn empty_active_device_clears_activity() {
    // "Nothing is playing anywhere" is a real state, not a missing value.
    assert!(!is_active_in_cluster("", Some("spotty_playback_1234")));
}

#[test]
fn no_local_device_id_is_never_active() {
    assert!(!is_active_in_cluster("phone-abc", None));
    assert!(!is_active_in_cluster("", None));
}

// The streaming session connects from credentials cached on disk, so that every init
// after the one-time grant needs no token at all. See
// plans/streaming-auth-needs-a-first-party-client-id.md.

#[test]
fn credentials_cache_dir_is_absolute_and_app_scoped() {
    let dir = credentials_cache_dir().expect("this environment must expose an absolute HOME");
    assert!(dir.is_absolute(), "cache dir must be absolute: {dir:?}");
    assert!(
        dir.ends_with("Spotty/credentials"),
        "cache dir must be app-scoped: {dir:?}"
    );
}

#[test]
fn credentials_cache_dir_uses_injected_home_without_tmp_fallback() {
    let dir = credentials_cache_dir_from_home(Some(std::path::Path::new(
        "/Users/tester/Library/Containers/app",
    )))
    .expect("absolute HOME is usable");
    assert_eq!(
        dir,
        std::path::PathBuf::from(
            "/Users/tester/Library/Containers/app/Library/Application Support/Spotty/credentials"
        )
    );

    assert_eq!(
        credentials_cache_dir_from_home(None),
        Err(CredentialsCacheError::Missing)
    );
    assert_eq!(
        credentials_cache_dir_from_home(Some(std::path::Path::new(""))),
        Err(CredentialsCacheError::Missing)
    );
    assert_eq!(
        credentials_cache_dir_from_home(Some(std::path::Path::new("Library"))),
        Err(CredentialsCacheError::Relative)
    );
    for shared in [
        "/tmp",
        "/tmp/",
        "/tmp/spotty",
        "/private/tmp",
        "/private/tmp/",
        "/private/tmp/spotty",
        "/var/tmp",
        "/private/var/tmp",
        "/var/../tmp",
        "/Users/../tmp",
        "/foo/../private/tmp",
        "/private/./tmp",
    ] {
        assert_eq!(
            credentials_cache_dir_from_home(Some(std::path::Path::new(shared))),
            Err(CredentialsCacheError::SharedTemporary),
            "shared temporary HOME must fail closed: {shared}"
        );
    }
}

#[cfg(unix)]
#[test]
fn credentials_cache_dir_is_created_private() {
    use std::os::unix::fs::PermissionsExt;
    let dir =
        std::env::temp_dir().join(format!("spotty-creds-mode-{}-private", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    ensure_private_credentials_dir(&dir).expect("create private cache dir");
    let mode = std::fs::metadata(&dir)
        .expect("cache dir metadata")
        .permissions()
        .mode()
        & 0o777;
    assert_eq!(
        mode, 0o700,
        "credential cache must not be group- or world-accessible"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_run_is_superseded_when_the_generation_moves() {
    // The grant writes credentials from inside Session::connect, so a logout landing
    // mid-connect must be detected afterwards — see AGENTS.md, a superseded run must
    // not write.
    assert!(!run_is_superseded(4, 4));
    assert!(run_is_superseded(4, 5));
    // A teardown that reset the counter is a supersession too, not a match.
    assert!(run_is_superseded(4, 0));
}

#[test]
fn generation_mutation_gate_serializes_event_state_and_invalidation() {
    let _guard = lock_global_state();
    let previous_generation = set_session_generation_for_test(41);
    let (entered_tx, entered_rx) = std::sync::mpsc::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    let event = std::thread::spawn(move || {
        let applied = with_current_generation_mutation(41, || {
            entered_tx
                .send(())
                .expect("the test must observe the event mutation before invalidation");
            release_rx
                .recv()
                .expect("the test must release the event mutation");
            true
        });
        assert_eq!(applied, Some(true));
    });
    entered_rx
        .recv()
        .expect("the event mutation should enter the generation gate");

    let (invalidated_tx, invalidated_rx) = std::sync::mpsc::channel();
    let invalidator = std::thread::spawn(move || {
        invalidated_tx
            .send(invalidate_cluster_generation())
            .expect("the test must report invalidation");
    });
    let invalidation_blocked = invalidated_rx
        .recv_timeout(Duration::from_millis(20))
        .is_err();

    release_tx
        .send(())
        .expect("the event mutation should be released");
    event.join().expect("event mutation thread");
    let invalidated = invalidated_rx
        .recv_timeout(Duration::from_secs(1))
        .expect("invalidation should finish after the event mutation");
    invalidator.join().expect("invalidation thread");
    assert!(
        invalidation_blocked,
        "invalidation must wait for the event's synchronous mutation to finish"
    );
    assert_eq!(invalidated, 42);
    set_session_generation_for_test(previous_generation);
}

#[test]
fn generation_owned_snapshot_keeps_its_callback_owner() {
    let _guard = lock_global_state();
    let previous_generation = set_session_generation_for_test(8);
    let stamp = stamped_snapshot_for_generation(7, |stamp| stamp);
    set_session_generation_for_test(9);

    assert_eq!(stamp.session_generation, 7);
    set_session_generation_for_test(previous_generation);
}

#[test]
fn stale_recovery_cannot_claim_the_reconnect_owner() {
    let _guard = lock_global_state();
    let previous_generation = set_session_generation_for_test(8);
    cancel_recovery();
    let intent = RecoveryIntent {
        was_playing: true,
        was_active: true,
    };

    let start = with_current_generation_mutation(7, || start_reconnect_loop(intent, 7));

    assert!(start.is_none(), "a stale event must not claim recovery");
    assert!(!recovery_is_active());
    cancel_recovery();
    set_session_generation_for_test(previous_generation);
}

fn lock_global_state() -> std::sync::MutexGuard<'static, ()> {
    lock_lifecycle_test_globals()
}

#[test]
fn routine_cleanup_does_not_supersede_a_grant() {
    let _guard = lock_global_state();
    // A grant waits on a human in a browser, which is long enough for an ordinary play,
    // retry or wake to rebuild the player underneath it. Those bump SESSION_GENERATION;
    // if the grant watched that counter it would report itself superseded and delete the
    // credentials it had just written.
    let before = LOGOUT_GENERATION.load(Ordering::SeqCst);
    let session_before = SESSION_GENERATION.load(Ordering::SeqCst);

    cleanup_player();

    assert_ne!(
        SESSION_GENERATION.load(Ordering::SeqCst),
        session_before,
        "cleanup is expected to move the session generation"
    );
    assert_eq!(
        LOGOUT_GENERATION.load(Ordering::SeqCst),
        before,
        "cleanup must not invalidate a streaming grant"
    );
}

#[test]
fn shutdown_supersedes_a_grant() {
    let _guard = lock_global_state();

    // Logout and app termination both go through here, and both mean the account this
    // grant belongs to is gone.
    let before = LOGOUT_GENERATION.load(Ordering::SeqCst);

    let _ = shutdown_player();

    assert!(run_is_superseded(
        before,
        LOGOUT_GENERATION.load(Ordering::SeqCst)
    ));

    // Leave the flag as the rest of the suite expects; init clears it in the app.
    SHUTTING_DOWN.store(false, Ordering::SeqCst);
}

#[test]
fn clearing_credentials_removes_the_directory() {
    // Deliberately parameterised: cargo test runs unsandboxed, so exercising this
    // against credentials_cache_dir() would delete the real credentials on this machine
    // every time the suite ran.
    let dir = std::env::temp_dir().join(format!("spotty-creds-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("create cache dir");
    std::fs::write(dir.join("credentials.json"), b"{}").expect("write credentials");
    assert!(dir.exists());

    clear_credentials_at(&dir);

    assert!(!dir.exists(), "logout must not leave credentials behind");
}

#[test]
fn clearing_retired_credentials_removes_only_the_retired_directory() {
    let root = std::env::temp_dir().join(format!(
        "spotty-retired-credential-cleanup-{}",
        std::process::id()
    ));
    let retired = root.join("Aural").join("credentials");
    let current = root.join("Spotty").join("credentials");
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&retired).expect("create retired fixture");
    std::fs::create_dir_all(&current).expect("create current fixture");
    std::fs::write(retired.join("credentials.json"), b"retired").expect("write retired fixture");
    std::fs::write(current.join("credentials.json"), b"current").expect("write current fixture");

    clear_retired_credentials_at(&retired);

    assert!(!retired.exists());
    assert!(!retired.parent().expect("retired parent").exists());
    assert_eq!(
        std::fs::read(current.join("credentials.json")).expect("read current fixture"),
        b"current"
    );
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn clearing_credentials_that_are_not_there_is_fine() {
    // Logging out without ever having authorized streaming is ordinary, not an error.
    let dir = std::env::temp_dir().join(format!("spotty-absent-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);

    clear_credentials_at(&dir);

    assert!(!dir.exists());
}

#[test]
fn control_snapshot_stamps_are_monotonic_and_session_scoped() {
    let _guard = lock_global_state();
    let expected_generation = SESSION_GENERATION.load(Ordering::SeqCst);

    let first = stamped_snapshot(|stamp| stamp);
    let second = stamped_snapshot(|stamp| stamp);

    assert_eq!(second.revision, first.revision + 1);
    assert_eq!(first.session_generation, expected_generation);
    assert_eq!(second.session_generation, expected_generation);
}

#[test]
fn aggregate_connection_pins_cluster_role_and_device_identity() {
    let connection = ConnectionState {
        is_active_device: true,
        device_id: Some("stale-device".to_string()),
        ..Default::default()
    };

    let pinned = pin_connection_to_cluster(connection, Some("cluster-device"), false);

    assert!(!pinned.is_active_device);
    assert_eq!(pinned.device_id.as_deref(), Some("cluster-device"));
}

#[test]
fn block_on_playback_runs_on_a_non_runtime_thread() {
    assert_eq!(block_on_playback(async { 9u8 }), Ok(9));
}

#[test]
fn block_on_playback_refuses_a_tokio_owned_thread() {
    let refused = RUNTIME.block_on(async { block_on_playback(async { 0i32 }) });
    assert_eq!(refused, Err(CommandError::Failed));
}

#[test]
fn init_player_nested_runtime_does_not_clear_teardown_flags() {
    let _guard = lock_global_state();
    cleanup_player();
    SHUTTING_DOWN.store(true, Ordering::SeqCst);
    SLEEPING.store(true, Ordering::SeqCst);

    let code = RUNTIME.block_on(async { initialize_player() });

    assert_eq!(code, Err(CommandError::Failed));
    assert!(
        SHUTTING_DOWN.load(Ordering::SeqCst),
        "nested init must not cancel an in-flight shutdown"
    );
    assert!(
        SLEEPING.load(Ordering::SeqCst),
        "nested init must not cancel sleep"
    );

    SHUTTING_DOWN.store(false, Ordering::SeqCst);
    SLEEPING.store(false, Ordering::SeqCst);
}

#[test]
fn protocol_context_clears_without_local_events_resurrecting_resume_context() {
    let _guard = lock_lifecycle_test_globals();
    let context = CURRENT_CONTEXT_URI.lock().unwrap().clone();
    let options = current_playback_options();
    let copied = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
    let observed = copied.clone();
    let _observer = client::TestObserver::install(move |notice| match notice {
        client::Observation::Cluster(cluster) => {
            observed
                .borrow_mut()
                .push(cluster.playback.unwrap().context);
        }
        client::Observation::Playback(playback) => observed.borrow_mut().push(playback.context),
        _ => {}
    });
    let generation = SESSION_GENERATION.load(Ordering::SeqCst);
    let mut state = PlayerState {
        context_uri: "spotify:playlist:authoritative".to_owned(),
        ..Default::default()
    };
    let cluster = |state| Cluster {
        player_state: protobuf::MessageField::some(state),
        ..Default::default()
    };
    apply_cluster(
        generation,
        ClusterOrigin::PushedUpdate,
        cluster(state.clone()),
    );
    state.context_uri.clear();
    apply_cluster(generation, ClusterOrigin::PushedUpdate, cluster(state));
    assert_eq!(
        CURRENT_CONTEXT_URI.lock().unwrap().as_deref(),
        Some("spotify:playlist:authoritative")
    );
    let local = capture_local_playback_state(true, 42, generation);
    deliver_local_playback_state(local);
    assert_eq!(
        *copied.borrow(),
        vec![
            Some("spotify:playlist:authoritative".to_owned()),
            Some(String::new()),
            None,
        ]
    );
    *CURRENT_CONTEXT_URI.lock().unwrap() = context;
    update_playback_options(options.0, options.1, options.2);
}

// The display getter advances the last Player report by the time since it arrived, bounded to
// one librespot update interval, so a timing sample no longer carries a 0-200 ms error.

#[test]
fn displayed_position_advances_by_elapsed_time_while_playing() {
    let displayed = interpolate_position_ms(1_000, 10_000, 10_120, true);
    assert_eq!(displayed, 1_120);
}

#[test]
fn displayed_position_is_capped_at_one_update_interval() {
    let displayed = interpolate_position_ms(1_000, 10_000, 20_000, true);
    let cap = POSITION_INTERPOLATION_CAP_MS as u32;
    assert_eq!(displayed, 1_000 + cap);
}

#[test]
fn displayed_position_is_raw_when_paused_or_never_reported() {
    let paused = interpolate_position_ms(1_000, 10_000, 10_120, false);
    assert_eq!(paused, 1_000);
    let never_reported = interpolate_position_ms(1_000, 0, 10_120, true);
    assert_eq!(never_reported, 1_000);
}

#[test]
fn displayed_position_survives_clock_wrap_and_saturates() {
    // The arrival time sits just below the 32-bit wrap; 120 ms later the clock has wrapped.
    let wrapped = interpolate_position_ms(1_000, u32::MAX - 19, 100, true);
    assert_eq!(wrapped, 1_120);
    let saturated = interpolate_position_ms(u32::MAX, 10_000, 10_100, true);
    assert_eq!(saturated, u32::MAX);
}

#[test]
fn position_report_packs_position_and_arrival_as_one_word() {
    let report = pack_position_report(4_242, 0x1_0000_0007);
    assert_eq!(unpack_position_report(report), (4_242, 7));
}

#[test]
fn update_position_records_when_the_report_arrived_and_reset_clears_it() {
    let _guard = lock_global_state();
    let saved_position = POSITION_MS.load(Ordering::SeqCst);
    let saved_report = POSITION_REPORT.load(Ordering::SeqCst);

    let before = monotonic_ms() as u32;
    update_position(4_242);
    let (position, reported_at) = unpack_position_report(POSITION_REPORT.load(Ordering::SeqCst));
    assert_eq!(POSITION_MS.load(Ordering::SeqCst), 4_242);
    assert_eq!(position, 4_242);
    let recent = reported_at.wrapping_sub(before) < 1_000;
    assert!(reported_at != 0 && recent);

    reset_position();
    assert_eq!(POSITION_MS.load(Ordering::SeqCst), 0);
    assert_eq!(POSITION_REPORT.load(Ordering::SeqCst), 0);

    POSITION_MS.store(saved_position, Ordering::SeqCst);
    POSITION_REPORT.store(saved_report, Ordering::SeqCst);
}
