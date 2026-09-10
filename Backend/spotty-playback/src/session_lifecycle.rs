use crate::*;

#[path = "credentials_cache.rs"]
mod credentials_cache;
pub(crate) use credentials_cache::*;

#[path = "session_construction.rs"]
mod session_construction;
pub(crate) use session_construction::*;

/// Whether the run that started at `started_generation` has been superseded.
pub(crate) fn run_is_superseded(started_generation: u64, current_generation: u64) -> bool {
    started_generation != current_generation
}

/// Removes the cached streaming credentials.
///
/// Call on logout, after the session teardown, so that the next launch cannot connect the
/// account that just logged out. Removing credentials that are not there is not an error.
#[no_mangle]
pub extern "C" fn spotty_playback_clear_streaming_credentials() {
    ffi_void("spotty_playback_clear_streaming_credentials", || {
        clear_resolved_credentials();
    })
}

/// Completes the one-time streaming authorization with a token Swift has already minted:
/// connects once and persists the credentials every later init connects from.
///
/// Returns 0 on success, -1 on failure, -2 if the run was superseded.
///
/// Swift owns the OAuth flow itself through `KeymasterAuth`; this call performs the librespot AP
/// connect and persists the streaming credentials for later initialization. The same grant also
/// authorizes pathfinder and spclient, so the token is minted by Swift before this call.
///
/// The token must be minted with Spotify's first-party desktop client ID; a token minted with a
/// user dashboard client ID is rejected by login5.
#[no_mangle]
pub extern "C" fn spotty_playback_authorize_streaming(access_token: *const c_char) -> i32 {
    ffi_command("spotty_playback_authorize_streaming", || {
        let started_generation = LOGOUT_GENERATION.load(Ordering::SeqCst);

        let token = match unsafe { c_string_arg(access_token) } {
            Some(t) if !t.is_empty() => t,
            _ => {
                debug!("Streaming authorization error: no access token");
                return -1;
            }
        };
        debug!("Streaming authorization: token received, connecting");

        // Connect once so librespot writes the AP credentials into the cache. Every init after
        // this connects from that cache with no token at all. Serialize this cache write with
        // reconnect and cleanup so a late rejection cannot remove a newer grant.
        let result: Result<(), i32> = match block_on_export(async {
            with_lifecycle_lock(async {
                // Do not start a credential write after logout has already won. This check and
                // the post-connect check remain inside the lifecycle lock, so another grant
                // cannot replace the cache between validation and a compensating clear.
                if run_is_superseded(started_generation, LOGOUT_GENERATION.load(Ordering::SeqCst)) {
                    return Err(-2);
                }

                let device_id = configured_device_id().ok_or_else(|| {
                    debug!(
                        "Streaming authorization error: installation identity is not configured"
                    );
                    -1
                })?;
                let (session, credentials) = match create_session(&device_id, Some(&token)) {
                    Ok(value) => value,
                    Err(_) => return Err(-1),
                };
                let mut session_guard = SessionShutdownGuard::new(session.clone());
                let connect_result = session.connect(credentials, true).await;
                // A failed or cancelled connect still owns AP/channel state until it is
                // explicitly invalidated. Do this before the local Session is dropped.
                session.shutdown();
                session_guard.disarm();
                if let Err(error) = connect_result {
                    let failure = classify_initialization_error(&error);
                    debug!("Streaming authorization connect failed ({:?})", failure);
                    return Err(-1);
                }

                if run_is_superseded(started_generation, LOGOUT_GENERATION.load(Ordering::SeqCst)) {
                    debug!("Streaming authorization superseded; removing its credentials");
                    clear_resolved_credentials();
                    return Err(-2);
                }

                clear_retired_credentials_cache();
                Ok(())
            })
            .await
        }) {
            Ok(result) => result,
            Err(code) => return code,
        };

        if let Err(code) = result {
            return code;
        }

        debug!("Streaming authorization complete");
        0
    })
}

/// Creates a new (unconnected) Session with the given device ID.
///
/// `access_token` is `Some` only for the first connect after the streaming grant. Every later
/// init passes `None` and connects from the credentials librespot cached then — which is the
/// point of the cache: no token, no refresh, no round-trip before connecting.
///
/// The token must be one minted with librespot's own client id. A Web API token minted with
/// the user's dashboard client id authenticates with the AP but is rejected by login5, which
/// is what took playback down entirely; see
/// `plans/streaming-auth-needs-a-first-party-client-id.md`.
pub(crate) fn create_session(
    device_id: &str,
    access_token: Option<&str>,
) -> Result<(Session, librespot_core::authentication::Credentials), String> {
    let session_config = SessionConfig {
        device_id: device_id.to_string(),
        ..Default::default()
    };
    let cache_dir = credentials_cache_dir().map_err(|error| error.message().to_string())?;
    ensure_private_credentials_dir(&cache_dir)?;
    let cache = Cache::new(Some(cache_dir), None, None, None)
        .map_err(|_| CredentialsCacheError::Missing.message().to_string())?;

    // Prefer a freshly granted token; otherwise reuse what the last grant cached. Resolved
    // here rather than at the call site so every caller gets the same rule.
    let credentials = match access_token {
        Some(token) => librespot_core::authentication::Credentials::with_access_token(token),
        None => cache
            .credentials()
            .ok_or_else(|| "No streaming credentials: authorization required".to_string())?,
    };
    let session = Session::new(session_config, Some(cache));
    Ok((session, credentials))
}

/// How often to check whether the current session needs recovery.
pub(crate) const SESSION_HEALTH_CHECK_INTERVAL: Duration = Duration::from_secs(60);

/// Watches for a session that is unusable while no other recovery owner is active.
///
/// Every other recovery trigger needs something to happen: the cluster listener only acts
/// when its stream *closes*, and librespot's dealer retries internally so the stream can
/// stay open for minutes past a dead session; the zombie check in
/// `require_session_connected` only runs when a command is issued. While Spotty is the
/// active device something trips one of those quickly. While it is *not* active, nothing
/// may. The same check also covers a partial initialization that stored a Session but never
/// reached the connected-and-Spirc-ready state. In either case it starts the normal
/// reconnect loop unless that loop or an intentional teardown already owns the lifecycle.
///
/// Cost is one sleeping task per generation, waking once a minute to read a few flags
/// (`Session::is_invalid` is a lock read of a `bool`). It exits when its generation is
/// superseded, so it dies with the session it belongs to rather than accumulating.
pub(crate) fn spawn_session_health_check(generation: u64) -> JoinHandle<()> {
    RUNTIME.spawn(async move {
        loop {
            tokio::time::sleep(SESSION_HEALTH_CHECK_INTERVAL).await;

            // Superseded: whatever replaced our session brought its own check.
            if !listener_may_act(generation, SESSION_GENERATION.load(Ordering::SeqCst)) {
                return;
            }

            // Sleep and shutdown invalidate the session on purpose.
            if teardown_in_progress() {
                continue;
            }

            let session_invalid = SESSION
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .as_ref()
                .is_some_and(|s| s.is_invalid());

            if health_check_should_recover(
                session_invalid,
                with_connection(|c| c.session_connected),
                recovery_is_active(),
                teardown_in_progress(),
            ) {
                debug!(
                    "Session health check: session {} needs recovery (invalid={})",
                    generation, session_invalid
                );
                let intent = RecoveryIntent::capture();
                mark_disconnected("Session unusable");
                spawn_reconnection_loop(intent);
                // Recovery owns it from here; the rebuild spawns the next check.
                return;
            }
        }
    })
}

/// Spawns the reconnection loop task.
/// Uses exponential backoff and rebuilds from the cached streaming credentials.
pub(crate) fn spawn_reconnection_loop(intent: RecoveryIntent) {
    // Capture the generation at trigger time, before the task is scheduled. A rebuild
    // that lands between here and the first poll would otherwise be adopted as "the
    // thing being recovered" and torn down on attempt 0.
    spawn_reconnection_loop_for_generation(intent, SESSION_GENERATION.load(Ordering::SeqCst));
}

/// Spawns recovery for a generation captured by the event that requested it.
///
/// A player event releases its short mutation gate before delivering callbacks and starting
/// recovery. Passing the listener generation through this boundary prevents a replacement that
/// lands in that gap from being adopted as the thing the stale event should rebuild.
pub(crate) fn spawn_reconnection_loop_for_generation(
    intent: RecoveryIntent,
    recovering_generation: u64,
) {
    let Some(Some(start)) = with_current_generation_mutation(recovering_generation, || {
        start_reconnect_loop(intent, recovering_generation)
    }) else {
        debug!(
            "[WAKE +{}ms] Reconnection skipped: generation superseded or already in progress",
            elapsed_since_wake_ms()
        );
        return;
    };

    debug!(
        "[WAKE +{}ms] spawn_reconnection_loop started",
        elapsed_since_wake_ms()
    );

    RUNTIME.spawn(async move {
        // The generation this loop is recovering. Between two attempts it can sleep for up
        // to 30 seconds, and during that time something else — a manual restart from the
        // wake path, or spotty_playback_cleanup on logout — may have already rebuilt or torn down
        // the session. Waking up and rebuilding anyway would replace a healthy new session
        // with one built from a stale token. An ownership flag alone cannot catch this: it says
        // "a loop is running", not "the thing it is fixing still exists".
        // Mutable on purpose: each rebuild attempt bumps SESSION_GENERATION itself, so the
        // loop adopts the value its own attempt produced. Without that it reads its own
        // work as a foreign supersede and gives up after a single failed attempt.
        let mut recovering_generation = start.recovering_generation;
        let intent = start.intent;
        let mut lease = start.lease;

        // Backoff that never gives up. This used to be a fixed schedule of ten attempts
        // totalling about three minutes, after which the loop exited — so an outage longer
        // than that left the app dead with nothing running to notice the network coming
        // back, and only a manual play would recover it. The loop is not idle polling: it
        // exists only while disconnected and exits on any lifecycle event, because every
        // iteration re-checks the generation and the teardown flags below.
        let mut attempt: u32 = 0;

        loop {
            let delay = recovery_delay(attempt);
            let attempt_number = attempt.saturating_add(1);
            attempt = attempt.saturating_add(1);
            if !lease.wait(delay).await {
                return;
            }

            if !reconnect_may_proceed(
                recovering_generation,
                SESSION_GENERATION.load(Ordering::SeqCst),
                teardown_in_progress(),
            ) {
                debug!(
                    "[WAKE +{}ms] Abandoning reconnect for generation {}: superseded or torn down",
                    elapsed_since_wake_ms(),
                    recovering_generation
                );
                return;
            }

            debug!(
                "[WAKE +{}ms] Reconnect attempt {}",
                elapsed_since_wake_ms(),
                attempt_number
            );
            let Some(Some(notification)) = with_current_generation_mutation(recovering_generation, || {
                if lease.is_cancelled() || teardown_in_progress() { return None; }
                with_connection(|c| {
                    c.last_error = Some(format!("Reconnecting (attempt {})", attempt_number));
                });
                capture_connection_state_notification(recovering_generation)
            }) else { return; };
            deliver_connection_state_notification(notification);

            // No token is fetched here. A rebuild connects from the AP credentials cached by
            // the streaming grant, which is the only login path this reconnection flow
            // performs (the initial connect in `create_session` may still use a token), so a
            // Swift token round-trip adds latency without changing the outcome of a network
            // outage. A definitive credential rejection is classified at Spirc construction and
            // exits this loop after invalidating only the cached streaming credential.

            // One recovery strategy: tear everything down and rebuild Session, Player,
            // Mixer and Spirc as a single generation, then restore the captured intent.
            //
            // There used to be a "soft reconnect" that kept the Player alive across
            // sessions to avoid an audible gap. It bought a shorter interruption at the
            // cost of a Player outliving the Session it was built for, which is what
            // forced the librespot patch that makes Spirc adopt an orphaned
            // play_request_id, the context-reload-after-reconnect blip, and a watchdog
            // that re-issued play commands when the audio key fetch on the dead session
            // silently timed out. A brief gap during an outage is the better trade.
            //
            // Cleanup and build share the lifecycle lock with a final generation
            // revalidation so a queued stale reconnect cannot tear down a newer session.
            match run_reconnect_unit_async(
                recovering_generation,
                || SESSION_GENERATION.load(Ordering::SeqCst),
                || teardown_in_progress() || lease.is_cancelled(),
                do_reconnect_cleanup,
                async {
                    let result =
                        build_player_owned(None, intent.was_active, intent.should_resume(), Some(&lease)).await;
                    // Capture the attempt and publish its failure while this lifecycle unit still
                    // owns the lock. A later build must not supply our generation or receive our error.
                    let generation = LAST_BUILD_GENERATION.load(Ordering::SeqCst);
                    if result == Err(InitializationFailure::Transient)
                        && listener_may_act(generation, SESSION_GENERATION.load(Ordering::SeqCst))
                        && !teardown_in_progress()
                        && !lease.is_cancelled()
                    {
                        with_connection(|c| c.last_error = Some("Reconnect failed".to_string()));
                        notify_connection_state_change();
                    }
                    (generation, result)
                },
            )
            .await
            {
                ReconnectUnitOutcome::Abandoned => {
                    debug!(
                        "[WAKE +{}ms] Abandoning reconnect for generation {}: superseded or torn down",
                        elapsed_since_wake_ms(),
                        recovering_generation
                    );
                        return;
                }
                ReconnectUnitOutcome::Ran((_, Ok(_))) => {
                    debug!(
                        "[WAKE +{}ms] Reconnect successful on attempt {}",
                        elapsed_since_wake_ms(),
                        attempt_number
                    );
                        return;
                }
                ReconnectUnitOutcome::Ran((attempt_generation, Err(e))) => {
                    debug!(
                        "[WAKE +{}ms] Reconnect attempt {} failed: {}",
                        elapsed_since_wake_ms(),
                        attempt_number,
                        e
                    );
                    if e == InitializationFailure::CredentialsRejected {
                        // A definitive rejection is terminal for this cached AP credential.
                        // `build_player_async` publishes the typed snapshot only after checking
                        // this attempt's generation; the reconnect owner must then stop rather
                        // than feeding the same unusable credential through the backoff forever.
                                return;
                    }
                    // Adopt the generation this attempt created. build_player_async bumps it
                    // before it can fail, so leaving the old value here would make the next
                    // iteration mistake our own rebuild for someone else's and abandon.
                    //
                    // Read from the attempt rather than from the counter: a logout and the
                    // login after it can both have bumped it while this attempt ran, and
                    // adopting *that* would have the loop rebuild over a session belonging
                    // to another account. Reading our own value leaves the next iteration's
                    // supersede check to notice and abandon, which is the right outcome.
                    recovering_generation = attempt_generation;
                }
            }
        }
    });
}

/// Forces a reconnection to Spotify servers.
///
/// Use this after system wake to ensure a fresh connection.
/// Returns:
/// - 0: Reconnection triggered.
/// - 1: Reconnection already in progress.
/// - 2: No session initialized (nothing to reconnect).
#[no_mangle]
pub extern "C" fn spotty_playback_force_reconnect() -> i32 {
    ffi_command("spotty_playback_force_reconnect", || {
        // Clear sleeping flag - we're explicitly waking up
        SLEEPING.store(false, Ordering::SeqCst);

        // Record wake timestamp for timing analysis
        let wake_ts = current_timestamp_ms();
        WAKE_TIMESTAMP_MS.store(wake_ts, Ordering::SeqCst);
        debug!(
            "[WAKE +0ms] spotty_playback_force_reconnect called at {}",
            wake_ts
        );

        // Check if we even have a session
        if SESSION.lock().unwrap_or_else(|e| e.into_inner()).is_none() {
            debug!(
                "[WAKE +{}ms] Force reconnect: no session initialized",
                elapsed_since_wake_ms()
            );
            return 2;
        }

        // Check if already reconnecting
        if recovery_is_active() {
            debug!(
                "[WAKE +{}ms] Force reconnect: reconnection already in progress",
                elapsed_since_wake_ms()
            );
            return 1;
        }

        debug!(
            "[WAKE +{}ms] Force reconnect: triggering reconnection",
            elapsed_since_wake_ms()
        );

        mark_disconnected("Reconnecting after system wake");
        spawn_reconnection_loop(RecoveryIntent::capture());

        0
    })
}

/// Performs full cleanup for reconnection.
/// Clears Session, Spirc, Player, and Mixer because Player is tightly coupled
/// to the Session's ChannelManager for decryption key requests.
pub(crate) async fn do_reconnect_cleanup() {
    debug!("do_reconnect_cleanup: full cleanup for reconnection");
    let _store = enter_store_section();
    teardown_engine_resources("do_reconnect_cleanup").await;
    with_connection(|c| c.spirc_ready = false);
    with_connection(|c| {
        c.device_id = None;
        c.session_connected = false;
        c.credentials_rejected = false;
        c.resume_pending = false;
    });

    debug!("do_reconnect_cleanup complete");
}

/// Initializes the player.
/// Must be called before play/pause operations.
///
/// # Parameters
/// - `access_token`: A token minted with librespot's client id, or null to connect from the
///   credentials cached by [`spotty_playback_authorize_streaming`]. Null is the normal case:
///   only the first init after a grant carries a token.
#[no_mangle]
pub extern "C" fn spotty_playback_init_player(
    access_token: SpottyNullableCString,
) -> SpottyPlaybackResult {
    ffi_command("spotty_playback_init_player", || {
        // Initialize env_logger to capture librespot's log output (only once)
        static LOGGER_INIT: std::sync::Once = std::sync::Once::new();
        LOGGER_INIT.call_once(|| {
            // try_init rather than init: Builder::init panics if another logger is already
            // installed, which would be a panic unwinding straight into Swift.
            let _ = env_logger::Builder::from_env(env_logger::Env::default())
                .format_timestamp_millis()
                .try_init();
        });

        // Print RUST_LOG env var for debugging
        let rust_log = std::env::var("RUST_LOG").unwrap_or_else(|_| "(not set)".to_string());
        debug!("RUST_LOG={}", rust_log);

        // A null token means "connect from the cached streaming credentials", which is the normal
        // case: only the first init after the one-time grant carries a token.
        let token_str = unsafe { c_string_arg(access_token) };

        // Already-initialized remains the established no-op: drop teardown flags and return
        // success without `block_on`. Nested-runtime refusal does not apply here because
        // this path never entered the runtime before the barrier either.
        if session_is_present() {
            SHUTTING_DOWN.store(false, Ordering::SeqCst);
            SLEEPING.store(false, Ordering::SeqCst);
            return 0;
        }

        // Refuse before clearing teardown flags: a Tokio-owned call used to panic inside
        // `block_on`, and mapping that to `ERROR_GENERAL` must not also look like a
        // successful reinitialization that cancelled shutdown or sleep.
        if let Err(code) = refuse_if_nested_runtime() {
            return code;
        }

        SHUTTING_DOWN.store(false, Ordering::SeqCst);
        SLEEPING.store(false, Ordering::SeqCst);

        let result = match block_on_export(async {
            // Recheck inside the serialization boundary: a reconnect may have stored a
            // session while this call waited for the lock.
            match run_serialized_init(session_is_present, async {
                cancel_recovery();
                build_player_async(token_str.as_deref(), false, false).await
            })
            .await
            {
                SerializedInitOutcome::AlreadyInitialized => {
                    SHUTTING_DOWN.store(false, Ordering::SeqCst);
                    SLEEPING.store(false, Ordering::SeqCst);
                    Ok(())
                }
                SerializedInitOutcome::Built(result) => result,
            }
        }) {
            Ok(result) => result,
            Err(code) => return code,
        };

        match result {
            Ok(_) => 0,
            Err(failure) => {
                debug!("Player init error: {}", failure);
                initialization_failure_code(failure)
            }
        }
    })
}
