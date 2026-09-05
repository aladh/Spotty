use super::*;

#[test]
fn connect_config_advertises_configured_device_name() {
    let name = "Studio Mac (Spotty)";
    assert_eq!(create_connect_config(name).name, name);
}

#[test]
fn connect_config_uses_device_name_written_through_ffi() {
    let expected = "Studio Mac (Spotty)";
    let name = CString::new(expected).expect("test device name is valid");
    spotty_playback_set_device_name(name.as_ptr());

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
    assert!(RecoveryIntent {
        was_playing: true,
        was_active: true
    }
    .should_resume());
}

#[test]
fn remote_playback_is_left_alone() {
    // Another device is still playing; taking over would steal it from the user.
    assert!(!RecoveryIntent {
        was_playing: true,
        was_active: false
    }
    .should_resume());
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
    assert!(!RecoveryIntent {
        was_playing: false,
        was_active: true
    }
    .should_resume());
}

#[test]
fn load_at_position_rejects_an_empty_uri_before_session_checks() {
    assert_eq!(
        load_at_position(String::new(), None, 0, false, 0),
        ERROR_GENERAL
    );
    assert_eq!(
        load_at_position(String::new(), Some("spotify:track:x".into()), 10, true, 0),
        ERROR_GENERAL
    );
}

#[test]
fn a_rehydration_load_runs_only_for_the_current_generation_with_an_open_window() {
    let _guard = lock_global_state();
    let previous_generation = SESSION_GENERATION.load(Ordering::SeqCst);
    let previous_pending = with_connection(|c| std::mem::replace(&mut c.resume_pending, false));

    SESSION_GENERATION.store(11, Ordering::SeqCst);
    let _ = open_rehydration_window(11);
    assert!(
        !rehydration_load_is_current(11),
        "window is not open until published"
    );

    with_connection(|c| c.resume_pending = true);
    assert!(rehydration_load_is_current(11));
    assert!(
        !rehydration_load_is_current(10),
        "a load for an older session is stale"
    );

    SESSION_GENERATION.store(12, Ordering::SeqCst);
    assert!(
        !rehydration_load_is_current(11),
        "a newer session supersedes the window even while the flag is set"
    );
    // Declined in the engine before any session lookup, so a queued Swift rehydration
    // cannot land in a later session.
    assert_eq!(
        load_at_position("spotify:track:x".into(), None, 0, false, 11),
        ERROR_GENERAL
    );

    with_connection(|c| c.resume_pending = previous_pending);
    SESSION_GENERATION.store(previous_generation, Ordering::SeqCst);
}

fn take_owned_c_string(ptr: *mut std::os::raw::c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    let value = unsafe { std::ffi::CStr::from_ptr(ptr) }
        .to_str()
        .ok()
        .map(str::to_owned);
    spotty_playback_free_string(ptr);
    value
}

#[test]
fn resume_identity_exports_read_session_globals() {
    let _guard = lock_global_state();
    *CURRENT_CONTEXT_URI.lock().unwrap() = Some("spotify:playlist:ctx".into());
    *CURRENT_TRACK_URI.lock().unwrap() = Some("spotify:track:one".into());
    assert_eq!(
        take_owned_c_string(spotty_playback_get_resume_context_uri()).as_deref(),
        Some("spotify:playlist:ctx")
    );
    assert_eq!(
        take_owned_c_string(spotty_playback_get_resume_track_uri()).as_deref(),
        Some("spotify:track:one")
    );

    *CURRENT_TRACK_URI.lock().unwrap() = Some(String::new());
    assert_eq!(
        take_owned_c_string(spotty_playback_get_resume_track_uri()).as_deref(),
        Some("")
    );

    *CURRENT_CONTEXT_URI.lock().unwrap() = None;
    *CURRENT_TRACK_URI.lock().unwrap() = None;
    assert_eq!(
        take_owned_c_string(spotty_playback_get_resume_context_uri()),
        None
    );
    assert_eq!(
        take_owned_c_string(spotty_playback_get_resume_track_uri()),
        None
    );
}

#[test]
fn resume_identity_is_present_only_for_a_nonempty_context_or_track() {
    let _guard = lock_global_state();
    *CURRENT_CONTEXT_URI.lock().unwrap() = None;
    *CURRENT_TRACK_URI.lock().unwrap() = None;
    assert!(!has_resume_identity());

    *CURRENT_CONTEXT_URI.lock().unwrap() = Some(String::new());
    *CURRENT_TRACK_URI.lock().unwrap() = Some(String::new());
    assert!(
        !has_resume_identity(),
        "empty strings are missing, matching the Swift plan's empty targets"
    );

    *CURRENT_TRACK_URI.lock().unwrap() = Some("spotify:track:solo".into());
    assert!(has_resume_identity());

    *CURRENT_CONTEXT_URI.lock().unwrap() = Some("spotify:playlist:ctx".into());
    *CURRENT_TRACK_URI.lock().unwrap() = None;
    assert!(has_resume_identity());

    *CURRENT_CONTEXT_URI.lock().unwrap() = None;
}

#[test]
fn rehydration_window_reports_playing_reinit_or_timeout() {
    let _guard = lock_global_state();

    // Opening resets a stale reinit flag and captures the sequence to wait past.
    REHYDRATION_NEEDS_REINIT.store(true, Ordering::SeqCst);
    let seq = open_rehydration_window(7);
    assert!(!REHYDRATION_NEEDS_REINIT.load(Ordering::SeqCst));
    assert_eq!(seq, playing_event_stamp().sequence);

    assert_eq!(
        RUNTIME.block_on(wait_for_rehydration(seq, Duration::ZERO)),
        RehydrationOutcome::TimedOut
    );

    // A closed-channel report from an older generation's load is stale and ignored.
    note_load_needs_reinit(6);
    assert_eq!(
        RUNTIME.block_on(wait_for_rehydration(seq, Duration::ZERO)),
        RehydrationOutcome::TimedOut
    );

    note_load_needs_reinit(7);
    assert_eq!(
        RUNTIME.block_on(wait_for_rehydration(seq, Duration::ZERO)),
        RehydrationOutcome::NeedsReinit
    );
    REHYDRATION_NEEDS_REINIT.store(false, Ordering::SeqCst);

    // A Playing event from a superseded pump advances the sequence but not this window.
    publish_playing_event(6);
    assert_eq!(
        RUNTIME.block_on(wait_for_rehydration(seq, Duration::ZERO)),
        RehydrationOutcome::TimedOut
    );

    // Merely writing the generation must never validate the older sequence: the current
    // generation has to publish its own Playing event.
    publish_playing_event(7);
    assert_eq!(
        RUNTIME.block_on(wait_for_rehydration(seq, Duration::ZERO)),
        RehydrationOutcome::Playing
    );
}

#[test]
fn connection_state_starts_without_an_open_rehydration_window() {
    assert!(!ConnectionState::default().resume_pending);
}

#[test]
fn playing_event_waits_observe_sequence_advances_and_timeouts() {
    let _guard = lock_global_state();
    let previous = playing_event_stamp().sequence;
    publish_playing_event(0);
    assert!(playing_event_advanced(previous));
    assert!(wait_for_playing_event(previous, Duration::ZERO));
    let current = playing_event_stamp().sequence;
    assert!(!playing_event_advanced(current));
    assert!(!wait_for_playing_event(current, Duration::ZERO));
}

#[test]
fn health_check_recovers_a_dead_session() {
    assert!(health_check_should_recover(true, false, false, false));
}

#[test]
fn health_check_recovers_a_session_that_never_connected() {
    // Regression: Session::is_invalid is only set by shutdown(), so a session left
    // behind by a failed init reports valid forever. Before this, nothing retried —
    // the Swift watchdog used to paper over it by rebuilding every 120s, and removing
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
    let previous_generation = SESSION_GENERATION.swap(41, Ordering::SeqCst);
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
    SESSION_GENERATION.store(previous_generation, Ordering::SeqCst);
}

#[test]
fn generation_owned_snapshot_keeps_its_callback_owner() {
    let _guard = lock_global_state();
    let previous_generation = SESSION_GENERATION.swap(8, Ordering::SeqCst);
    let stamp = stamped_snapshot_for_generation(7, |stamp| stamp);
    SESSION_GENERATION.store(9, Ordering::SeqCst);

    assert_eq!(stamp.session_generation, 7);
    SESSION_GENERATION.store(previous_generation, Ordering::SeqCst);
}

#[test]
fn stale_recovery_cannot_claim_the_reconnect_owner() {
    let _guard = lock_global_state();
    let previous_generation = SESSION_GENERATION.swap(8, Ordering::SeqCst);
    let previous_reconnecting = RECONNECTING.swap(false, Ordering::SeqCst);
    let intent = RecoveryIntent {
        was_playing: true,
        was_active: true,
    };

    let start = with_current_generation_mutation(7, || start_reconnect_loop(intent, 7));

    assert!(start.is_none(), "a stale event must not claim recovery");
    assert!(!RECONNECTING.load(Ordering::SeqCst));
    RECONNECTING.store(previous_reconnecting, Ordering::SeqCst);
    SESSION_GENERATION.store(previous_generation, Ordering::SeqCst);
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

    spotty_playback_cleanup();

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

    let _ = spotty_playback_shutdown();

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

/// The checked-in C fixture uses Clang's canonical function-type spelling. Keep each row paired
/// with a Rust assignment here: a changed Rust `extern "C"` definition fails to compile, while
/// `Scripts/check.sh` compares these C spellings to the parsed header before linking the archive.
#[derive(Debug, Eq, PartialEq)]
struct ExportedCFunctionSignature {
    name: String,
    function_type: String,
}

fn exported_c_function_signatures() -> Vec<ExportedCFunctionSignature> {
    let mut signatures = Vec::new();
    macro_rules! signature {
        ($function:ident, $rust_type:ty, $c_type:literal) => {{
            let _: $rust_type = $function;
            signatures.push(ExportedCFunctionSignature {
                name: stringify!($function).to_owned(),
                function_type: $c_type.to_owned(),
            });
        }};
    }

    signature!(
        spotty_playback_add_to_queue,
        extern "C" fn(*const c_char) -> i32,
        "SpottyPlaybackResult (const char *)"
    );
    signature!(
        spotty_playback_authorize_streaming,
        extern "C" fn(*const c_char) -> i32,
        "int32_t (const char *)"
    );
    signature!(spotty_playback_cleanup, extern "C" fn(), "void (void)");
    signature!(
        spotty_playback_clear_streaming_credentials,
        extern "C" fn(),
        "void (void)"
    );
    signature!(
        spotty_playback_disconnect,
        extern "C" fn() -> i32,
        "SpottyPlaybackResult (void)"
    );
    signature!(
        spotty_playback_force_reconnect,
        extern "C" fn() -> i32,
        "int32_t (void)"
    );
    signature!(
        spotty_playback_free_queue_snapshot,
        extern "C" fn(*mut SpottyQueueSnapshot),
        "void (SpottyQueueSnapshot *)"
    );
    signature!(
        spotty_playback_free_string,
        extern "C" fn(*mut c_char),
        "void (char *)"
    );
    signature!(
        spotty_playback_get_position_ms,
        extern "C" fn() -> u32,
        "uint32_t (void)"
    );
    signature!(
        spotty_playback_get_queue_snapshot,
        extern "C" fn() -> *mut SpottyQueueSnapshot,
        "SpottyQueueSnapshot * (void)"
    );
    signature!(
        spotty_playback_get_resume_context_uri,
        extern "C" fn() -> *mut c_char,
        "char * (void)"
    );
    signature!(
        spotty_playback_get_resume_position_ms,
        extern "C" fn() -> u32,
        "uint32_t (void)"
    );
    signature!(
        spotty_playback_get_resume_track_uri,
        extern "C" fn() -> *mut c_char,
        "char * (void)"
    );
    signature!(
        spotty_playback_init_player,
        extern "C" fn(*const c_char) -> i32,
        "SpottyPlaybackResult (const char *)"
    );
    signature!(
        spotty_playback_load,
        extern "C" fn(*const c_char, *const c_char, u32, bool, u64) -> i32,
        "SpottyPlaybackResult (const char *, const char *, uint32_t, _Bool, uint64_t)"
    );
    signature!(
        spotty_playback_next,
        extern "C" fn() -> i32,
        "SpottyPlaybackResult (void)"
    );
    signature!(
        spotty_playback_pause,
        extern "C" fn() -> i32,
        "SpottyPlaybackResult (void)"
    );
    signature!(
        spotty_playback_play_tracks,
        extern "C" fn(*const c_char) -> i32,
        "SpottyPlaybackResult (const char *)"
    );
    signature!(
        spotty_playback_play_uri,
        extern "C" fn(*const c_char) -> i32,
        "SpottyPlaybackResult (const char *)"
    );
    signature!(
        spotty_playback_previous,
        extern "C" fn() -> i32,
        "SpottyPlaybackResult (void)"
    );
    signature!(
        spotty_playback_register_audio_control_callback,
        extern "C" fn(extern "C" fn(u8)),
        "void (AudioControlCallback)"
    );
    signature!(
        spotty_playback_register_audio_data_callback,
        extern "C" fn(extern "C" fn(*const f32, usize)),
        "void (AudioDataCallback)"
    );
    signature!(
        spotty_playback_register_connection_state_callback,
        extern "C" fn(ConnectionSnapshotCallback),
        "void (ConnectionStateCallback)"
    );
    signature!(
        spotty_playback_register_devices_callback,
        extern "C" fn(DevicesSnapshotCallback),
        "void (DevicesCallback)"
    );
    signature!(
        spotty_playback_register_playback_state_callback,
        extern "C" fn(PlaybackSnapshotCallback),
        "void (PlaybackStateCallback)"
    );
    signature!(
        spotty_playback_register_queue_callback,
        extern "C" fn(QueueSnapshotCallback),
        "void (QueueCallback)"
    );
    signature!(
        spotty_playback_resume,
        extern "C" fn() -> i32,
        "SpottyPlaybackResult (void)"
    );
    signature!(
        spotty_playback_seek,
        extern "C" fn(u32) -> i32,
        "SpottyPlaybackResult (uint32_t)"
    );
    signature!(
        spotty_playback_set_device_name,
        extern "C" fn(*const c_char),
        "void (const char *)"
    );
    signature!(
        spotty_playback_set_repeat_context,
        extern "C" fn(bool) -> i32,
        "SpottyPlaybackResult (_Bool)"
    );
    signature!(
        spotty_playback_set_repeat_track,
        extern "C" fn(bool) -> i32,
        "SpottyPlaybackResult (_Bool)"
    );
    signature!(
        spotty_playback_set_shuffle,
        extern "C" fn(bool) -> i32,
        "SpottyPlaybackResult (_Bool)"
    );
    signature!(
        spotty_playback_shutdown,
        extern "C" fn() -> i32,
        "SpottyPlaybackResult (void)"
    );
    signature!(
        spotty_playback_transfer_playback,
        extern "C" fn(*const c_char) -> i32,
        "SpottyPlaybackResult (const char *)"
    );
    signature!(
        spotty_playback_transfer_to_local,
        extern "C" fn() -> i32,
        "SpottyPlaybackResult (void)"
    );

    signatures.sort_by(|a, b| a.name.cmp(&b.name));
    signatures
}

fn parse_abi_signature_fixture(fixture: &str) -> Vec<ExportedCFunctionSignature> {
    let mut signatures = fixture
        .lines()
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .map(|line| {
            let (name, function_type) = line
                .split_once('|')
                .unwrap_or_else(|| panic!("ABI fixture row has no separator: {line}"));
            assert!(
                name.starts_with("spotty_playback_"),
                "ABI fixture row has an invalid export name: {name}"
            );
            assert!(
                !function_type.is_empty(),
                "ABI fixture row has no type: {name}"
            );
            ExportedCFunctionSignature {
                name: name.to_owned(),
                function_type: function_type.to_owned(),
            }
        })
        .collect::<Vec<_>>();
    signatures.sort_by(|a, b| a.name.cmp(&b.name));
    signatures
}

/// Compile-time ABI contract. The release archive is also checked with `nm`; the assignments
/// make Rust signature drift fail in the fast test suite before reaching the linker check.
#[test]
fn exported_c_function_signatures_are_stable() {
    let signatures = exported_c_function_signatures();
    assert_eq!(signatures.len(), 35);
}

/// The checked-in C fixture is compared to the header by `Scripts/check.sh`; this Rust-side
/// assertion keeps its C spellings paired with the type-checked `extern "C"` definitions above.
#[test]
fn exported_c_function_signatures_match_fixture() {
    let fixture = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/abi-signatures.txt"));
    assert_eq!(
        parse_abi_signature_fixture(fixture),
        exported_c_function_signatures()
    );
}

/// Compiles a C consumer with the same header and shim that Swift imports, then compares every
/// retained C layout value with Rust's `repr(C)` type at runtime. Keeping the expected values
/// derived from Rust means a one-sided field/order change fails this test instead of silently
/// passing a table of duplicated constants. The compiler step is intentionally in the test
/// binary: it adds no production export or dependency and exercises the actual C consumer ABI.
#[test]
fn c_consumer_layout_matches_rust_repr_c_layouts() {
    use std::collections::BTreeMap;
    use std::path::{Path, PathBuf};
    use std::process::Command;

    struct TempDirectory(PathBuf);

    impl Drop for TempDirectory {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    let manifest_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    let include_dir = manifest_dir.join("../../Sources/SpottyPlaybackCore/include");
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock is after the Unix epoch")
        .as_nanos();
    let probe_dir = std::env::temp_dir().join(format!(
        "spotty-c-rust-abi-{}-{}",
        std::process::id(),
        nonce
    ));
    std::fs::create_dir(&probe_dir).expect("create temporary ABI probe directory");
    let _temporary_directory = TempDirectory(probe_dir.clone());
    let source_path = probe_dir.join("probe.c");
    let binary_path = probe_dir.join("probe");

    let source = r#"
#include "spotty_playback.h"
#include <stddef.h>
#include <stdio.h>

#define EMIT_TYPE(T) \
    printf("type|%s|size|%zu\n", #T, sizeof(T)); \
    printf("type|%s|align|%zu\n", #T, _Alignof(T))
#define EMIT_FIELD(T, F) \
    printf("field|%s|%s|%zu\n", #T, #F, offsetof(T, F))
#define EMIT_PRIMITIVE(LABEL, T) \
    printf("primitive|%s|size|%zu\n", LABEL, sizeof(T)); \
    printf("primitive|%s|align|%zu\n", LABEL, _Alignof(T))

int main(void) {
    EMIT_PRIMITIVE("uint8_t", uint8_t);
    EMIT_PRIMITIVE("uint16_t", uint16_t);
    EMIT_PRIMITIVE("uint32_t", uint32_t);
    EMIT_PRIMITIVE("uint64_t", uint64_t);
    EMIT_PRIMITIVE("int32_t", int32_t);
    EMIT_PRIMITIVE("int64_t", int64_t);
    EMIT_PRIMITIVE("size_t", size_t);
    EMIT_PRIMITIVE("_Bool", _Bool);
    EMIT_PRIMITIVE("pointer", void*);

    EMIT_TYPE(SpottyStringPair);
    EMIT_FIELD(SpottyStringPair, key);
    EMIT_FIELD(SpottyStringPair, value);

    EMIT_TYPE(SpottyRestriction);
    EMIT_FIELD(SpottyRestriction, key);
    EMIT_FIELD(SpottyRestriction, reasons);
    EMIT_FIELD(SpottyRestriction, reason_count);

    EMIT_TYPE(SpottyProtocolQueueTrack);
    EMIT_FIELD(SpottyProtocolQueueTrack, uri);
    EMIT_FIELD(SpottyProtocolQueueTrack, uid);
    EMIT_FIELD(SpottyProtocolQueueTrack, provider);
    EMIT_FIELD(SpottyProtocolQueueTrack, metadata);
    EMIT_FIELD(SpottyProtocolQueueTrack, metadata_count);
    EMIT_FIELD(SpottyProtocolQueueTrack, removed);
    EMIT_FIELD(SpottyProtocolQueueTrack, removed_count);
    EMIT_FIELD(SpottyProtocolQueueTrack, blocked);
    EMIT_FIELD(SpottyProtocolQueueTrack, blocked_count);
    EMIT_FIELD(SpottyProtocolQueueTrack, restrictions);
    EMIT_FIELD(SpottyProtocolQueueTrack, restriction_count);
    EMIT_FIELD(SpottyProtocolQueueTrack, album_uri);
    EMIT_FIELD(SpottyProtocolQueueTrack, disallow_reasons);
    EMIT_FIELD(SpottyProtocolQueueTrack, disallow_reason_count);
    EMIT_FIELD(SpottyProtocolQueueTrack, artist_uri);

    EMIT_TYPE(SpottyQueueSnapshot);
    EMIT_FIELD(SpottyQueueSnapshot, revision);
    EMIT_FIELD(SpottyQueueSnapshot, session_generation);
    EMIT_FIELD(SpottyQueueSnapshot, track_uri);
    EMIT_FIELD(SpottyQueueSnapshot, track_provider);
    EMIT_FIELD(SpottyQueueSnapshot, track_uid);
    EMIT_FIELD(SpottyQueueSnapshot, next_tracks);
    EMIT_FIELD(SpottyQueueSnapshot, next_count);
    EMIT_FIELD(SpottyQueueSnapshot, prev_tracks);
    EMIT_FIELD(SpottyQueueSnapshot, prev_count);
    EMIT_FIELD(SpottyQueueSnapshot, queue_revision);
    EMIT_FIELD(SpottyQueueSnapshot, disallow_set_queue);
    EMIT_FIELD(SpottyQueueSnapshot, disallow_removing_from_next_tracks);

    EMIT_TYPE(SpottyPlaybackSnapshot);
    EMIT_FIELD(SpottyPlaybackSnapshot, revision);
    EMIT_FIELD(SpottyPlaybackSnapshot, session_generation);
    EMIT_FIELD(SpottyPlaybackSnapshot, position_ms);
    EMIT_FIELD(SpottyPlaybackSnapshot, duration_ms);
    EMIT_FIELD(SpottyPlaybackSnapshot, timestamp_ms);
    EMIT_FIELD(SpottyPlaybackSnapshot, is_playing);
    EMIT_FIELD(SpottyPlaybackSnapshot, is_paused);
    EMIT_FIELD(SpottyPlaybackSnapshot, track_unavailable);
    EMIT_FIELD(SpottyPlaybackSnapshot, shuffle);
    EMIT_FIELD(SpottyPlaybackSnapshot, repeat_track);
    EMIT_FIELD(SpottyPlaybackSnapshot, repeat_context);
    EMIT_FIELD(SpottyPlaybackSnapshot, is_active_device);
    EMIT_FIELD(SpottyPlaybackSnapshot, track_uri);

    EMIT_TYPE(SpottyProtocolDevice);
    EMIT_FIELD(SpottyProtocolDevice, id);
    EMIT_FIELD(SpottyProtocolDevice, name);
    EMIT_FIELD(SpottyProtocolDevice, device_type);

    EMIT_TYPE(SpottyDevicesSnapshot);
    EMIT_FIELD(SpottyDevicesSnapshot, revision);
    EMIT_FIELD(SpottyDevicesSnapshot, session_generation);
    EMIT_FIELD(SpottyDevicesSnapshot, active_device_id);
    EMIT_FIELD(SpottyDevicesSnapshot, devices);
    EMIT_FIELD(SpottyDevicesSnapshot, device_count);

    EMIT_TYPE(SpottyConnectionSnapshot);
    EMIT_FIELD(SpottyConnectionSnapshot, revision);
    EMIT_FIELD(SpottyConnectionSnapshot, session_generation);
    EMIT_FIELD(SpottyConnectionSnapshot, session_connected);
    EMIT_FIELD(SpottyConnectionSnapshot, spirc_ready);
    EMIT_FIELD(SpottyConnectionSnapshot, is_active_device);
    EMIT_FIELD(SpottyConnectionSnapshot, resume_pending);
    EMIT_FIELD(SpottyConnectionSnapshot, credentials_rejected);
    EMIT_FIELD(SpottyConnectionSnapshot, device_id);
    EMIT_FIELD(SpottyConnectionSnapshot, last_error);

    EMIT_TYPE(SpottyPlaybackResult);
    printf("enum|SpottyPlaybackResult|value|SpottyPlaybackResultOk|%d\n", (int)SpottyPlaybackResultOk);
    printf("enum|SpottyPlaybackResult|value|SpottyPlaybackResultError|%d\n", (int)SpottyPlaybackResultError);
    printf("enum|SpottyPlaybackResult|value|SpottyPlaybackResultSessionDisconnected|%d\n", (int)SpottyPlaybackResultSessionDisconnected);
    printf("enum|SpottyPlaybackResult|value|SpottyPlaybackResultSessionNotConnected|%d\n", (int)SpottyPlaybackResultSessionNotConnected);
    printf("enum|SpottyPlaybackResult|value|SpottyPlaybackResultCredentialsRejected|%d\n", (int)SpottyPlaybackResultCredentialsRejected);

    EMIT_TYPE(SpottyPlaybackAudioControlEvent);
    printf("enum|SpottyPlaybackAudioControlEvent|value|SpottyPlaybackAudioControlEventStop|%d\n", (int)SpottyPlaybackAudioControlEventStop);
    printf("enum|SpottyPlaybackAudioControlEvent|value|SpottyPlaybackAudioControlEventStart|%d\n", (int)SpottyPlaybackAudioControlEventStart);
    printf("enum|SpottyPlaybackAudioControlEvent|value|SpottyPlaybackAudioControlEventClear|%d\n", (int)SpottyPlaybackAudioControlEventClear);
    return 0;
}
"#;
    std::fs::write(&source_path, source).expect("write C ABI probe");

    let compile = Command::new("clang")
        .args([
            "-std=c11",
            source_path.to_str().expect("probe path is UTF-8"),
            "-I",
            include_dir.to_str().expect("header path is UTF-8"),
            "-o",
            binary_path.to_str().expect("binary path is UTF-8"),
        ])
        .output()
        .expect("clang is required for the C consumer ABI proof");
    assert!(
        compile.status.success(),
        "clang could not compile the C consumer ABI probe: {}",
        String::from_utf8_lossy(&compile.stderr)
    );

    let run = Command::new(&binary_path)
        .output()
        .expect("run C ABI probe");
    assert!(
        run.status.success(),
        "C ABI probe failed: {}",
        String::from_utf8_lossy(&run.stderr)
    );

    let mut c_values = BTreeMap::new();
    for line in String::from_utf8(run.stdout)
        .expect("C ABI probe output is UTF-8")
        .lines()
    {
        let fields = line.split('|').collect::<Vec<_>>();
        assert!(fields.len() >= 3, "malformed C ABI probe row: {line}");
        let value = fields.last().expect("ABI row has a value");
        let key = fields[..fields.len() - 1].join("|");
        assert!(
            c_values.insert(key, value.to_string()).is_none(),
            "C ABI probe emitted a duplicate row: {line}"
        );
    }

    let mut rust_values = BTreeMap::new();
    macro_rules! rust_primitive {
        ($name:literal, $ty:ty) => {{
            rust_values.insert(
                format!("primitive|{}|size", $name),
                std::mem::size_of::<$ty>().to_string(),
            );
            rust_values.insert(
                format!("primitive|{}|align", $name),
                std::mem::align_of::<$ty>().to_string(),
            );
        }};
    }
    rust_primitive!("uint8_t", u8);
    rust_primitive!("uint16_t", u16);
    rust_primitive!("uint32_t", u32);
    rust_primitive!("uint64_t", u64);
    rust_primitive!("int32_t", i32);
    rust_primitive!("int64_t", i64);
    rust_primitive!("size_t", usize);
    rust_primitive!("_Bool", bool);
    rust_primitive!("pointer", *const c_char);

    macro_rules! rust_layout {
        ($name:literal, $ty:ty, $( $field:ident ),+ $(,)?) => {{
            rust_values.insert(
                format!("type|{}|size", $name),
                std::mem::size_of::<$ty>().to_string(),
            );
            rust_values.insert(
                format!("type|{}|align", $name),
                std::mem::align_of::<$ty>().to_string(),
            );
            $(
                rust_values.insert(
                    format!("field|{}|{}", $name, stringify!($field)),
                    std::mem::offset_of!($ty, $field).to_string(),
                );
            )+
        }};
    }
    rust_layout!("SpottyStringPair", SpottyStringPair, key, value);
    rust_layout!(
        "SpottyRestriction",
        SpottyRestriction,
        key,
        reasons,
        reason_count
    );
    rust_layout!(
        "SpottyProtocolQueueTrack",
        SpottyProtocolQueueTrack,
        uri,
        uid,
        provider,
        metadata,
        metadata_count,
        removed,
        removed_count,
        blocked,
        blocked_count,
        restrictions,
        restriction_count,
        album_uri,
        disallow_reasons,
        disallow_reason_count,
        artist_uri
    );
    rust_layout!(
        "SpottyQueueSnapshot",
        SpottyQueueSnapshot,
        revision,
        session_generation,
        track_uri,
        track_provider,
        track_uid,
        next_tracks,
        next_count,
        prev_tracks,
        prev_count,
        queue_revision,
        disallow_set_queue,
        disallow_removing_from_next_tracks
    );
    rust_layout!(
        "SpottyPlaybackSnapshot",
        SpottyPlaybackSnapshot,
        revision,
        session_generation,
        position_ms,
        duration_ms,
        timestamp_ms,
        is_playing,
        is_paused,
        track_unavailable,
        shuffle,
        repeat_track,
        repeat_context,
        is_active_device,
        track_uri
    );
    rust_layout!(
        "SpottyProtocolDevice",
        SpottyProtocolDevice,
        id,
        name,
        device_type
    );
    rust_layout!(
        "SpottyDevicesSnapshot",
        SpottyDevicesSnapshot,
        revision,
        session_generation,
        active_device_id,
        devices,
        device_count
    );
    rust_layout!(
        "SpottyConnectionSnapshot",
        SpottyConnectionSnapshot,
        revision,
        session_generation,
        session_connected,
        spirc_ready,
        is_active_device,
        resume_pending,
        credentials_rejected,
        device_id,
        last_error
    );
    rust_values.insert(
        "type|SpottyPlaybackResult|size".to_string(),
        std::mem::size_of::<i32>().to_string(),
    );
    rust_values.insert(
        "type|SpottyPlaybackResult|align".to_string(),
        std::mem::align_of::<i32>().to_string(),
    );
    for (name, value) in [
        ("SpottyPlaybackResultOk", 0),
        ("SpottyPlaybackResultError", ERROR_GENERAL),
        (
            "SpottyPlaybackResultSessionDisconnected",
            ERROR_NEEDS_REINIT,
        ),
        (
            "SpottyPlaybackResultSessionNotConnected",
            ERROR_NOT_CONNECTED,
        ),
        (
            "SpottyPlaybackResultCredentialsRejected",
            ERROR_CREDENTIALS_REJECTED,
        ),
    ] {
        rust_values.insert(
            format!("enum|SpottyPlaybackResult|value|{name}"),
            value.to_string(),
        );
    }
    rust_values.insert(
        "type|SpottyPlaybackAudioControlEvent|size".to_string(),
        std::mem::size_of::<u8>().to_string(),
    );
    rust_values.insert(
        "type|SpottyPlaybackAudioControlEvent|align".to_string(),
        std::mem::align_of::<u8>().to_string(),
    );
    for (name, value) in [
        ("SpottyPlaybackAudioControlEventStop", 0),
        ("SpottyPlaybackAudioControlEventStart", 1),
        ("SpottyPlaybackAudioControlEventClear", 2),
    ] {
        rust_values.insert(
            format!("enum|SpottyPlaybackAudioControlEvent|value|{name}"),
            value.to_string(),
        );
    }

    assert_eq!(
        c_values, rust_values,
        "C consumer and Rust repr(C) ABI layouts or enum encodings differ"
    );
}

#[test]
fn connection_snapshot_callback_copies_nullable_fields() {
    extern "C" fn capture(snapshot: *const SpottyConnectionSnapshot) {
        let snapshot = unsafe { &*snapshot };
        assert_eq!(snapshot.revision, 14);
        assert_eq!(snapshot.session_generation, 5);
        assert_eq!(snapshot.session_connected, 1);
        assert_eq!(snapshot.spirc_ready, 1);
        assert_eq!(snapshot.is_active_device, 1);
        assert_eq!(snapshot.resume_pending, 1);
        assert_eq!(snapshot.credentials_rejected, 1);
        assert!(!snapshot.device_id.is_null());
        assert_eq!(
            unsafe { CStr::from_ptr(snapshot.device_id) }
                .to_str()
                .unwrap(),
            "fixture-mac"
        );
        assert!(snapshot.last_error.is_null());
    }

    send_connection_snapshot(
        capture,
        SnapshotStamp {
            revision: 14,
            session_generation: 5,
        },
        &ConnectionState {
            session_connected: true,
            spirc_ready: true,
            device_id: Some("fixture-mac".to_string()),
            last_error: None,
            credentials_rejected: true,
            is_active_device: true,
            resume_pending: true,
        },
    );

    extern "C" fn capture_missing(snapshot: *const SpottyConnectionSnapshot) {
        let snapshot = unsafe { &*snapshot };
        assert_eq!(snapshot.resume_pending, 0);
        assert_eq!(snapshot.credentials_rejected, 0);
        assert!(snapshot.device_id.is_null());
        assert!(!snapshot.last_error.is_null());
        assert_eq!(
            unsafe { CStr::from_ptr(snapshot.last_error) }
                .to_str()
                .unwrap(),
            "fixture-session-timeout"
        );
    }

    send_connection_snapshot(
        capture_missing,
        SnapshotStamp {
            revision: 2,
            session_generation: 1,
        },
        &ConnectionState {
            session_connected: false,
            spirc_ready: false,
            device_id: None,
            last_error: Some("fixture-session-timeout".to_string()),
            credentials_rejected: false,
            is_active_device: false,
            resume_pending: false,
        },
    );

    extern "C" fn capture_empty_and_nul(snapshot: *const SpottyConnectionSnapshot) {
        let snapshot = unsafe { &*snapshot };
        assert!(snapshot.device_id.is_null());
        assert!(snapshot.last_error.is_null());
        assert_eq!(snapshot.credentials_rejected, 0);
    }

    send_connection_snapshot(
        capture_empty_and_nul,
        SnapshotStamp {
            revision: 3,
            session_generation: 1,
        },
        &ConnectionState {
            session_connected: false,
            spirc_ready: false,
            device_id: Some(String::new()),
            last_error: Some("err\0or".to_string()),
            credentials_rejected: false,
            is_active_device: false,
            resume_pending: false,
        },
    );
}

#[test]
fn playback_snapshot_callback_copies_nullable_fields() {
    extern "C" fn capture(snapshot: *const SpottyPlaybackSnapshot) {
        let snapshot = unsafe { &*snapshot };
        assert_eq!(snapshot.revision, 12);
        assert_eq!(snapshot.session_generation, 4);
        assert_eq!(snapshot.is_playing, 1);
        assert_eq!(snapshot.is_paused, 0);
        assert_eq!(snapshot.track_unavailable, 0);
        assert_eq!(snapshot.shuffle, 1);
        assert_eq!(snapshot.repeat_track, 0);
        assert_eq!(snapshot.repeat_context, 1);
        assert_eq!(snapshot.is_active_device, 1);
        assert_eq!(snapshot.position_ms, 1_250);
        assert_eq!(snapshot.duration_ms, 180_000);
        assert_eq!(snapshot.timestamp_ms, 1_700_000_000_000);
        assert!(!snapshot.track_uri.is_null());
        assert_eq!(
            unsafe { CStr::from_ptr(snapshot.track_uri) }
                .to_str()
                .unwrap(),
            "spotify:track:fixtureNow"
        );
    }

    send_playback_snapshot(
        capture,
        SnapshotStamp {
            revision: 12,
            session_generation: 4,
        },
        &PlaybackObservation {
            is_playing: true,
            is_paused: false,
            track_unavailable: false,
            track_uri: "spotify:track:fixtureNow".to_string(),
            position_ms: 1_250,
            duration_ms: 180_000,
            shuffle: true,
            repeat_track: false,
            repeat_context: true,
            is_active_device: true,
            timestamp_ms: 1_700_000_000_000,
        },
    );

    extern "C" fn capture_unavailable(snapshot: *const SpottyPlaybackSnapshot) {
        let snapshot = unsafe { &*snapshot };
        assert_eq!(snapshot.track_unavailable, 1);
        assert_eq!(snapshot.is_playing, 0);
        assert_eq!(snapshot.is_paused, 1);
    }

    send_playback_snapshot(
        capture_unavailable,
        SnapshotStamp {
            revision: 13,
            session_generation: 4,
        },
        &PlaybackObservation {
            is_playing: false,
            is_paused: true,
            track_unavailable: true,
            track_uri: "spotify:track:fixtureUnavailable".to_string(),
            position_ms: 0,
            duration_ms: 0,
            shuffle: false,
            repeat_track: false,
            repeat_context: false,
            is_active_device: true,
            timestamp_ms: 1_700_000_000_001,
        },
    );

    extern "C" fn capture_empty_and_nul(snapshot: *const SpottyPlaybackSnapshot) {
        let snapshot = unsafe { &*snapshot };
        assert!(snapshot.track_uri.is_null());
        assert_eq!(snapshot.is_playing, 0);
        assert_eq!(snapshot.is_paused, 0);
        assert_eq!(snapshot.track_unavailable, 0);
        assert_eq!(snapshot.is_active_device, 0);
    }

    for track_uri in ["", "track\0uri"] {
        send_playback_snapshot(
            capture_empty_and_nul,
            SnapshotStamp {
                revision: 1,
                session_generation: 1,
            },
            &PlaybackObservation {
                is_playing: false,
                is_paused: false,
                track_unavailable: false,
                track_uri: track_uri.to_string(),
                position_ms: 0,
                duration_ms: 0,
                shuffle: false,
                repeat_track: false,
                repeat_context: false,
                is_active_device: false,
                timestamp_ms: 0,
            },
        );
    }
}

#[test]
fn devices_snapshot_callback_copies_nullable_fields() {
    extern "C" fn capture(snapshot: *const SpottyDevicesSnapshot) {
        let snapshot = unsafe { &*snapshot };
        assert_eq!(snapshot.revision, 15);
        assert_eq!(snapshot.session_generation, 6);
        assert!(!snapshot.active_device_id.is_null());
        assert_eq!(
            unsafe { CStr::from_ptr(snapshot.active_device_id) }
                .to_str()
                .unwrap(),
            "fixture-mac"
        );
        assert_eq!(snapshot.device_count, 2);
        assert!(!snapshot.devices.is_null());
        let rows = unsafe { std::slice::from_raw_parts(snapshot.devices, snapshot.device_count) };
        assert!(!rows[0].id.is_null());
        assert_eq!(
            unsafe { CStr::from_ptr(rows[0].id) }.to_str().unwrap(),
            "fixture-mac"
        );
        assert_eq!(
            unsafe { CStr::from_ptr(rows[0].name) }.to_str().unwrap(),
            "Fixture Mac"
        );
        assert_eq!(
            unsafe { CStr::from_ptr(rows[0].device_type) }
                .to_str()
                .unwrap(),
            "Computer"
        );
        assert_eq!(
            unsafe { CStr::from_ptr(rows[1].id) }.to_str().unwrap(),
            "fixture-speaker"
        );
    }

    send_devices_snapshot(
        capture,
        SnapshotStamp {
            revision: 15,
            session_generation: 6,
        },
        "fixture-mac",
        &[
            ProtocolConnectDevice {
                id: "fixture-mac".to_string(),
                name: "Fixture Mac".to_string(),
                device_type: "Computer".to_string(),
            },
            ProtocolConnectDevice {
                id: "fixture-speaker".to_string(),
                name: "Fixture Speaker".to_string(),
                device_type: "Speaker".to_string(),
            },
        ],
    );

    extern "C" fn capture_empty_and_nul(snapshot: *const SpottyDevicesSnapshot) {
        let snapshot = unsafe { &*snapshot };
        assert!(snapshot.active_device_id.is_null());
        assert_eq!(snapshot.device_count, 1);
        let rows = unsafe { std::slice::from_raw_parts(snapshot.devices, snapshot.device_count) };
        assert!(rows[0].id.is_null());
        assert!(rows[0].name.is_null());
        assert_eq!(
            unsafe { CStr::from_ptr(rows[0].device_type) }
                .to_str()
                .unwrap(),
            "Computer"
        );
    }

    send_devices_snapshot(
        capture_empty_and_nul,
        SnapshotStamp {
            revision: 1,
            session_generation: 1,
        },
        "",
        &[ProtocolConnectDevice {
            id: String::new(),
            name: "bad\0name".to_string(),
            device_type: "Computer".to_string(),
        }],
    );
}

#[test]
fn ffi_command_panic_returns_general_error() {
    assert_eq!(
        ffi_command("test_command", || panic!("token-payload-must-not-abort")),
        ERROR_GENERAL
    );
}

#[test]
fn ffi_query_panic_returns_conservative_zero_or_false() {
    assert_eq!(
        ffi_query_i32("test_flag", || panic!("token-payload-must-not-abort")),
        0
    );
    assert_eq!(
        ffi_query_u32("test_u32", || panic!("token-payload-must-not-abort")),
        0
    );
    assert_eq!(
        ffi_query_u8("test_u8", || panic!("token-payload-must-not-abort")),
        0
    );
    assert!(!ffi_query_bool("test_bool", || panic!(
        "token-payload-must-not-abort"
    )));
}

#[test]
fn ffi_owned_string_panic_returns_null() {
    let ptr = ffi_owned_string("test_string", || panic!("token-payload-must-not-abort"));
    assert!(ptr.is_null());
}

#[test]
fn ffi_void_panic_is_a_noop() {
    ffi_void("test_void", || panic!("token-payload-must-not-abort"));
}

#[test]
fn ffi_helpers_return_the_work_value_when_they_do_not_panic() {
    assert_eq!(ffi_command("ok_command", || 7), 7);
    assert_eq!(ffi_query_i32("ok_flag", || 1), 1);
    assert_eq!(ffi_query_u32("ok_u32", || 42), 42);
    assert_eq!(ffi_query_u8("ok_u8", || 2), 2);
    assert!(ffi_query_bool("ok_bool", || true));
    assert!(ffi_owned_string("ok_string", std::ptr::null_mut).is_null());
    let mut completed = false;
    ffi_void("ok_void", || completed = true);
    assert!(completed);
}

#[test]
fn block_on_export_runs_on_a_non_runtime_thread() {
    assert_eq!(block_on_export(async { 9u8 }), Ok(9));
}

#[test]
fn block_on_export_refuses_a_tokio_owned_thread() {
    let refused = RUNTIME.block_on(async { block_on_export(async { 0i32 }) });
    assert_eq!(refused, Err(ERROR_GENERAL));
}

#[test]
fn init_player_nested_runtime_does_not_clear_teardown_flags() {
    let _guard = lock_global_state();
    spotty_playback_cleanup();
    SHUTTING_DOWN.store(true, Ordering::SeqCst);
    SLEEPING.store(true, Ordering::SeqCst);

    let code = RUNTIME.block_on(async { spotty_playback_init_player(std::ptr::null()) });

    assert_eq!(code, ERROR_GENERAL);
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

const FFI_PANIC_BARRIERS: &[&str] = &[
    "ffi_command",
    "ffi_query_i32",
    "ffi_query_u32",
    "ffi_query_u8",
    "ffi_query_bool",
    "ffi_owned_string",
    "ffi_owned_ptr",
    "ffi_void",
];

/// Structural ABI companion to [`exported_c_function_signatures_are_stable`].
///
/// Walks Rust sources rather than line numbers: every `pub extern "C"` export must enter
/// through a named panic-barrier helper, and only `runtime.rs` may call `RUNTIME.block_on`.
#[test]
fn exported_c_functions_enter_through_the_panic_barrier() {
    let src_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut exports = Vec::new();
    for entry in std::fs::read_dir(&src_dir).expect("src dir") {
        let path = entry.expect("dir entry").path();
        if path.extension().and_then(|ext| ext.to_str()) != Some("rs") {
            continue;
        }
        let source = std::fs::read_to_string(&path).expect("read rust source");
        let file_name = path.file_name().and_then(|name| name.to_str());
        let is_test_module = file_name == Some("tests.rs")
            || file_name.is_some_and(|name| name.ends_with("_tests.rs"));
        if file_name != Some("runtime.rs") && !is_test_module {
            assert!(
                !source.contains("RUNTIME.block_on"),
                "{} must call block_on_export rather than RUNTIME.block_on",
                path.display()
            );
        }
        exports.extend(exported_c_functions(&source));
    }

    exports.sort_by(|a, b| a.0.cmp(&b.0));
    assert!(
        !exports.is_empty(),
        "expected to find exported C functions in spotty-playback sources"
    );
    for (name, barrier) in &exports {
        assert!(
            FFI_PANIC_BARRIERS.contains(&barrier.as_str()),
            "{name} enters through {barrier}, which is not a panic-barrier helper"
        );
    }
}

/// `Spirc::load` Ok is queued, not playing. `resume_playback` trusts `IS_PLAYING` for its
/// early return, so a queued `play_uri` / `play_tracks` load must not store true.
/// Production code (excluding `tests.rs` / `*_tests.rs` and `#[cfg(test)]` modules) may
/// write `IS_PLAYING=true` only from the `PlayerEvent::Playing` arm.
#[test]
fn only_a_playing_event_stores_is_playing_true() {
    let src_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut files_with_true_store = Vec::new();
    let mut playing_arm_stores_true = false;
    for entry in std::fs::read_dir(&src_dir).expect("src dir") {
        let path = entry.expect("dir entry").path();
        if path.extension().and_then(|ext| ext.to_str()) != Some("rs") {
            continue;
        }
        let file_name = path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or_default();
        if file_name == "tests.rs" || file_name.ends_with("_tests.rs") {
            continue;
        }
        let source = std::fs::read_to_string(&path).expect("read rust source");
        let production = strip_cfg_test_modules(&source);
        if code_contains(&production, "IS_PLAYING.store(true") {
            files_with_true_store.push(file_name.to_string());
        }
        if file_name == "player_event_pump.rs" {
            playing_arm_stores_true = code_contains(
                &match_arm_body(&production, "PlayerEvent::Playing"),
                "IS_PLAYING.store(true",
            );
        }
    }
    files_with_true_store.sort();
    assert_eq!(
        files_with_true_store,
        vec!["player_event_pump.rs".to_string()],
        "queued play commands must not store IS_PLAYING=true"
    );
    assert!(
        playing_arm_stores_true,
        "PlayerEvent::Playing must remain the authoritative IS_PLAYING=true write"
    );
}

fn strip_cfg_test_modules(source: &str) -> String {
    let bytes = source.as_bytes();
    let marker = "#[cfg(test)]";
    let mut out = String::new();
    let mut search_from = 0;
    while let Some(rel) = source[search_from..].find(marker) {
        let attr_start = search_from + rel;
        out.push_str(&source[search_from..attr_start]);
        let after_attr = attr_start + marker.len();
        let ident = skip_ws_and_comments(bytes, after_attr);
        if source[ident..].starts_with("mod ") {
            let name_start = ident + 4;
            let name_end = source[name_start..]
                .find(|c: char| !c.is_ascii_alphanumeric() && c != '_')
                .map(|idx| name_start + idx)
                .unwrap_or(source.len());
            let after_name = skip_ws_and_comments(bytes, name_end);
            if after_name < bytes.len() && bytes[after_name] == b'{' {
                search_from = matching_brace(bytes, after_name) + 1;
                continue;
            }
            if after_name < bytes.len() && bytes[after_name] == b';' {
                search_from = after_name + 1;
                continue;
            }
        }
        out.push_str(marker);
        search_from = after_attr;
    }
    out.push_str(&source[search_from..]);
    out
}

#[test]
fn strip_cfg_test_modules_keeps_production_after_a_test_module() {
    let source = concat!(
        "fn before() {}\n",
        "#[cfg(test)]\n",
        "mod tests {\n",
        "    IS_PLAYING.store(true, Ordering::SeqCst);\n",
        "}\n",
        "fn after() { IS_PLAYING.store(true, Ordering::SeqCst); }\n",
    );
    let stripped = strip_cfg_test_modules(source);
    assert!(
        !code_contains(&stripped, "mod tests"),
        "the test module body must be omitted"
    );
    assert!(
        code_contains(&stripped, "fn after"),
        "production after a test module must still be scanned"
    );
    assert!(code_contains(&stripped, "IS_PLAYING.store(true"));
}

fn code_contains(source: &str, needle: &str) -> bool {
    let bytes = source.as_bytes();
    let needle = needle.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        match scan_code_byte(bytes, i) {
            Scan::Skip(next) => i = next,
            Scan::Byte(_, next) => {
                if bytes[i..].starts_with(needle) {
                    return true;
                }
                i = next;
            }
        }
    }
    false
}

fn match_arm_body(source: &str, pattern: &str) -> String {
    let start = source
        .find(pattern)
        .unwrap_or_else(|| panic!("missing {pattern}"));
    let bytes = source.as_bytes();
    let arrow = start
        + source[start..]
            .find("=>")
            .unwrap_or_else(|| panic!("{pattern} is not a match arm"));
    let brace = next_unquoted(bytes, arrow + 2, b'{')
        .unwrap_or_else(|| panic!("{pattern} arm has no body"));
    let end = matching_brace(bytes, brace);
    source[brace + 1..end].to_string()
}

fn matching_brace(bytes: &[u8], open: usize) -> usize {
    let mut depth = 0usize;
    let mut i = open;
    while i < bytes.len() {
        match scan_code_byte(bytes, i) {
            Scan::Skip(next) => i = next,
            Scan::Byte(b, next) => {
                if b == b'{' {
                    depth += 1;
                } else if b == b'}' {
                    depth -= 1;
                    if depth == 0 {
                        return i;
                    }
                }
                i = next;
            }
        }
    }
    panic!("unbalanced brace")
}

fn exported_c_functions(source: &str) -> Vec<(String, String)> {
    let bytes = source.as_bytes();
    let needle = b"pub extern \"C\" fn ";
    let mut found = Vec::new();
    let mut search_from = 0;
    while let Some(rel) = source[search_from..].find("pub extern \"C\" fn ") {
        let start = search_from + rel;
        let name_start = start + needle.len();
        let name_end = source[name_start..]
            .find(|c: char| !c.is_ascii_alphanumeric() && c != '_')
            .map(|idx| name_start + idx)
            .unwrap_or(source.len());
        let name = source[name_start..name_end].to_string();
        let brace = match next_unquoted(bytes, name_end, b'{') {
            Some(idx) => idx,
            None => panic!("export {name} has no function body"),
        };
        let first = first_identifier_in_block(bytes, brace + 1);
        found.push((name, first));
        search_from = brace + 1;
    }
    found
}

fn next_unquoted(bytes: &[u8], from: usize, target: u8) -> Option<usize> {
    let mut i = from;
    while i < bytes.len() {
        match scan_code_byte(bytes, i) {
            Scan::Skip(next) => i = next,
            Scan::Byte(b, next) => {
                if b == target {
                    return Some(i);
                }
                i = next;
            }
        }
    }
    None
}

fn first_identifier_in_block(bytes: &[u8], from: usize) -> String {
    let i = skip_ws_and_comments(bytes, from);
    if i >= bytes.len() {
        panic!("function body ended before a call");
    }
    match bytes[i] {
        b'a'..=b'z' | b'A'..=b'Z' | b'_' => {
            let start = i;
            let mut end = i + 1;
            while end < bytes.len() && (bytes[end].is_ascii_alphanumeric() || bytes[end] == b'_') {
                end += 1;
            }
            std::str::from_utf8(&bytes[start..end])
                .expect("identifier")
                .to_string()
        }
        _ => panic!(
            "function body must start with a panic-barrier helper call, found {:?}",
            bytes[i] as char
        ),
    }
}

fn skip_ws_and_comments(bytes: &[u8], mut i: usize) -> usize {
    loop {
        while i < bytes.len() && bytes[i].is_ascii_whitespace() {
            i += 1;
        }
        if i + 1 < bytes.len() && bytes[i] == b'/' && bytes[i + 1] == b'/' {
            i += 2;
            while i < bytes.len() && bytes[i] != b'\n' {
                i += 1;
            }
            continue;
        }
        if i + 1 < bytes.len() && bytes[i] == b'/' && bytes[i + 1] == b'*' {
            i += 2;
            while i + 1 < bytes.len() && !(bytes[i] == b'*' && bytes[i + 1] == b'/') {
                i += 1;
            }
            i = i.saturating_add(2).min(bytes.len());
            continue;
        }
        return i;
    }
}

enum Scan {
    Skip(usize),
    Byte(u8, usize),
}

fn scan_code_byte(bytes: &[u8], i: usize) -> Scan {
    if i + 1 < bytes.len() && bytes[i] == b'/' && bytes[i + 1] == b'/' {
        let mut j = i + 2;
        while j < bytes.len() && bytes[j] != b'\n' {
            j += 1;
        }
        return Scan::Skip(j);
    }
    if i + 1 < bytes.len() && bytes[i] == b'/' && bytes[i + 1] == b'*' {
        let mut j = i + 2;
        while j + 1 < bytes.len() && !(bytes[j] == b'*' && bytes[j + 1] == b'/') {
            j += 1;
        }
        return Scan::Skip(j.saturating_add(2).min(bytes.len()));
    }
    if bytes[i] == b'"' {
        return Scan::Skip(skip_quoted(bytes, i, b'"'));
    }
    if bytes[i] == b'\'' {
        return Scan::Skip(skip_quoted(bytes, i, b'\''));
    }
    Scan::Byte(bytes[i], i + 1)
}

fn skip_quoted(bytes: &[u8], start: usize, quote: u8) -> usize {
    let mut i = start + 1;
    let mut escape = false;
    while i < bytes.len() {
        let b = bytes[i];
        if escape {
            escape = false;
        } else if b == b'\\' {
            escape = true;
        } else if b == quote {
            return i + 1;
        }
        i += 1;
    }
    bytes.len()
}
