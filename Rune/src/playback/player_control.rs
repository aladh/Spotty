use crate::playback::selection_load_policy::{SelectionLoadPolicy, SelectionOrder};
use crate::playback::*;

/// Helper to check if session is connected. Returns CommandError::NotConnected if not.
///
/// Also detects zombie sessions: the Session object may have been invalidated
/// (e.g. server closed the connection overnight) without the event listener
/// ever firing SessionDisconnected (because the Spirc task was idle).
/// When detected, updates state and triggers reconnection proactively.
pub(crate) fn require_session_connected(generation: u64) -> Result<(), CommandError> {
    let transition = with_current_generation_mutation(generation, || {
        let recovery = with_engine_owned(generation, |engine| {
            if !engine.connection.session_connected || !engine.owns_resources() {
                return Err(CommandError::NotConnected);
            }
            if !engine.session_missing_or_invalid() {
                return Ok(None);
            }
            engine.connection.session_connected = false;
            engine.connection.last_error = Some("Session expired".to_owned());
            Ok(Some(RecoveryIntent {
                was_playing: engine.is_playing(),
                was_active: engine.connection.is_active_device,
            }))
        })
        .unwrap_or(Err(CommandError::NotConnected))?;
        Ok(recovery.map(|intent| (intent, capture_connection_state_notification(generation))))
    })
    .unwrap_or(Err(CommandError::NotConnected))?;

    if let Some((intent, notification)) = transition {
        deliver_connection_state_notification(notification);
        spawn_reconnection_loop_for_generation(intent, generation);
        return Err(CommandError::NotConnected);
    }
    Ok(())
}

/// Runs a short, synchronous Spirc operation against the generation that admitted it.
/// The closure may prepare an owned notification, but delivery must occur after this returns.
pub(crate) fn with_command_spirc<T>(
    generation: u64,
    work: impl FnOnce(&Spirc) -> Result<T, CommandError>,
) -> Result<T, CommandError> {
    with_session_spirc(generation, false, work)
}

fn with_session_spirc<T>(
    generation: u64,
    transfer: bool,
    work: impl FnOnce(&Spirc) -> Result<T, CommandError>,
) -> Result<T, CommandError> {
    require_session_connected(generation)?;
    with_current_generation_mutation(generation, || {
        let spirc = with_engine_owned(generation, |engine| {
            if engine.connection.session_connected
                && engine.owns_resources()
                && !teardown_in_progress()
                && (transfer || !engine.observed_resume.remote_owner)
            {
                engine.spirc()
            } else {
                None
            }
        })
        .ok()
        .flatten()
        .ok_or(CommandError::NotConnected)?;
        work(&spirc)
    })
    .unwrap_or(Err(CommandError::NotConnected))
}

pub(crate) fn send_spirc_command(
    generation: u64,
    description: &str,
    send: impl FnOnce(&Spirc) -> Result<(), librespot_core::Error>,
) -> Result<(), CommandError> {
    with_command_spirc(generation, |spirc| {
        send(spirc).map_err(|error| spirc_error(description, &error))
    })
}

pub(crate) fn play_tracks(generation: u64, tracks: &[String]) -> Result<(), CommandError> {
    if tracks.is_empty() {
        return Err(CommandError::Failed);
    }
    enqueue_selection(generation, SelectionOrder::Supplied, |options| {
        LoadRequest::from_tracks(tracks.to_vec(), options)
    })
}

pub(crate) fn play_uri(generation: u64, input: &str) -> Result<(), CommandError> {
    let Some(uri) = url_to_uri(input) else {
        return Err(CommandError::Failed);
    };
    if uri.starts_with("spotify:track:") {
        enqueue_selection(generation, SelectionOrder::Supplied, |options| {
            LoadRequest::from_tracks(vec![uri], options)
        })
    } else {
        enqueue_selection(generation, SelectionOrder::Context, |options| {
            LoadRequest::from_context_uri(uri, options)
        })
    }
}

fn enqueue_selection(
    generation: u64,
    order: SelectionOrder,
    request: impl FnOnce(LoadRequestOptions) -> LoadRequest,
) -> Result<(), CommandError> {
    let (result, notification) = match with_command_spirc(generation, |spirc| {
        let request = request(SelectionLoadPolicy::capture(order).options(0, None));
        let activated = if is_active_device() {
            false
        } else {
            spirc
                .activate()
                .map_err(|error| spirc_error("Activate", &error))?;
            store_active_device(true)
        };
        let result = spirc
            .load(request)
            .map_err(|error| spirc_error("Play", &error));
        let notification = activated.then(|| capture_connection_state_notification(generation));
        Ok((result, notification))
    }) {
        Ok(outcome) => outcome,
        Err(error) => return Err(error),
    };
    if let Some(notification) = notification {
        deliver_connection_state_notification(notification);
    }
    result
}

pub(crate) fn shutdown_player() -> Result<(), CommandError> {
    debug!("shutdown_player called");
    // Prevent reconnection attempts during intentional shutdown
    SHUTTING_DOWN.store(true, Ordering::SeqCst);
    cancel_recovery();

    // The account is going away, so any streaming grant still waiting on a browser no longer
    // belongs to anyone. Only here — not in cleanup, which runs on every ordinary rebuild.
    LOGOUT_GENERATION.fetch_add(1, Ordering::SeqCst);

    // Publish the shutdown before closing Spirc so the worker cannot adopt the old session.
    with_connection(|c| {
        c.spirc_ready = false;
        c.session_connected = false;
        c.last_error = Some("Shutdown requested".to_string());
    });
    notify_connection_state_change();

    spirc_command("Shutdown", |spirc| spirc.shutdown())
}

#[cfg(target_os = "macos")]
pub(crate) fn disconnect_player() -> Result<(), CommandError> {
    debug!("disconnect_player called - disconnecting for sleep");
    // Set sleeping flag to prevent auto-reconnect when cluster listener ends
    SLEEPING.store(true, Ordering::SeqCst);
    cancel_recovery();

    let Some(spirc) = current_spirc("Disconnect") else {
        return Err(CommandError::NotConnected);
    };

    // First pause playback to stop producing new audio
    let _ = spirc.pause();
    debug!("disconnect_player: paused playback");

    // Clear the audio buffer synchronously to flush any remaining samples.
    // This must complete before we return, otherwise stale audio plays on wake — and it
    // blocks, which is the second reason `current_spirc` hands out a clone rather than a
    // guard.
    proxy_sink::ProxySink::clear_buffer();
    debug!("disconnect_player: audio buffer cleared");

    // Now shutdown Spirc (disconnect from Spotify Connect)
    match spirc.shutdown() {
        Ok(()) => {
            debug!("disconnect_player: spirc shutdown complete");
            Ok(())
        }
        Err(error) => Err(spirc_error("Disconnect", &error)),
    }
}

pub(crate) fn cleanup_player() {
    debug!("cleanup_player called - clearing all state");

    // A callback from a Tokio worker cannot safely re-enter the process runtime. Refuse
    // before touching the generation: the old objects remain installed and can finish under
    // their owner, rather than leaving an invalidated but still-live generation behind.
    if refuse_if_nested_runtime().is_err() {
        debug!("cleanup_player: refusing nested-runtime cleanup");
        return;
    }

    // Wait for an in-flight apply_cluster, then bump generation under the same gate
    // lock so mapping cannot begin for the outgoing session. A popped-not-yet-mapping
    // item is not waited on; begin_cluster_mapping re-checks after that gap.
    // Same-thread mapping (callback → cleanup) does not wait. The bump remains
    // before the lifecycle lock so an in-flight commit can observe supersession.
    let invalidated = invalidate_cluster_generation();
    cancel_recovery();
    debug!("cleanup_player invalidated generation, now {}", invalidated);

    match block_on_playback(async {
        with_lifecycle_lock(async {
            cleanup_player_globals().await;
        })
        .await;
    }) {
        Ok(()) => {}
        Err(_) => {
            // The refusal above normally handles this. Keep this guard for a runtime
            // transition between the check and `block_on_playback`; no unlocked writes are
            // safe while an in-flight build owns the lifecycle lock.
            debug!("cleanup_player: refusing nested-runtime cleanup");
        }
    }
}

/// Clears engine globals and session-scoped playback identity.
///
/// Callers that write these stores must already hold the lifecycle lock.
pub(crate) async fn cleanup_player_globals() {
    let _store = enter_store_section();
    teardown_engine_resources("cleanup_player").await;

    // Reset state flags
    clear_engine_playing();
    set_active_device(false);
    update_playback_options(false, false, false);
    reset_position();
    // Belongs to the session being torn down. Surviving a logout would let a resume seek to
    // an offset from the previous lifecycle, or another account's playback.
    RESUME_POSITION_MS.store(0, Ordering::SeqCst);
    // Rehydration reads these sticky identities with the saved position. Full cleanup must
    // clear all three so a later account cannot reload this account's context or track.
    // Reconnect uses `do_reconnect_cleanup`, which retains them for the same account.
    *CURRENT_TRACK_URI.lock().unwrap_or_else(|e| e.into_inner()) = None;
    *CURRENT_CONTEXT_URI
        .lock()
        .unwrap_or_else(|e| e.into_inner()) = None;
    // Queued cluster offers belong to the account being retired.
    discard_retained_cluster_offers();

    // Reset the connection snapshot: not ready, not connected, no device ID, no open
    // rehydration window.
    with_connection(|c| {
        c.spirc_ready = false;
        c.session_connected = false;
        c.resume_pending = false;
        c.device_id = None;
        c.credentials_rejected = false;
        c.last_error = None;
    });

    // Notify connection state change
    notify_connection_state_change();

    debug!("cleanup_player complete - ready for reinitialization");
}

/// librespot emits `PositionChanged` every 200 ms while playing, so a raw report read at an
/// arbitrary instant is 0-200 ms behind the audible position. The display getter advances the
/// report by the time since it arrived, but never by more than this, so a Player that has gone
/// quiet (pause, stall, teardown) freezes within one update interval of its last report.
/// Unbounded interpolation used to run on for seconds after events stopped while reconnect
/// rehydration resumed from the raw report; the two then snapped several seconds apart.
/// Internal readers (resume capture, deactivation save, snapshots) read `POSITION_MS` raw.
pub(crate) const POSITION_INTERPOLATION_CAP_MS: u64 = 250;

/// Pure form of the display getter: the reported position advanced by the bounded elapsed time.
/// Arrival and current times are the low 32 bits of `monotonic_ms`; wrapping subtraction keeps
/// the elapsed time right across the 49-day wrap, and a zero arrival means no report.
pub(crate) fn interpolate_position_ms(
    reported_ms: u32,
    reported_at_ms: u32,
    now_ms: u32,
    playing: bool,
) -> u32 {
    if !playing || reported_at_ms == 0 {
        return reported_ms;
    }
    let elapsed = u64::from(now_ms.wrapping_sub(reported_at_ms)).min(POSITION_INTERPOLATION_CAP_MS);
    u32::try_from(u64::from(reported_ms) + elapsed).unwrap_or(u32::MAX)
}

/// The position to display: the last report, advanced by at most one update interval while
/// playing. Rune interpolates between its own samples; this only removes the
/// 0-200 ms sampling error each sample would otherwise carry.
pub(crate) fn displayed_position_ms() -> u32 {
    let (reported_ms, reported_at_ms) =
        unpack_position_report(POSITION_REPORT.load(Ordering::SeqCst));
    interpolate_position_ms(
        reported_ms,
        reported_at_ms,
        monotonic_ms() as u32,
        engine_is_playing(),
    )
}

#[cfg(any(test, target_os = "macos"))]
pub(crate) fn set_connect_device_name(device_name: &str) {
    let device_name = device_name.trim();
    if !device_name.is_empty() {
        *CONNECT_DEVICE_NAME_SETTING
            .lock()
            .unwrap_or_else(|poison| poison.into_inner()) = Some(device_name.to_owned());
    }
}

pub(crate) fn transfer_to_local(generation: u64) -> Result<(), CommandError> {
    with_session_spirc(generation, true, |spirc| {
        spirc
            .transfer(None)
            .map_err(|error| spirc_error("Transfer", &error))
    })
}

pub(crate) fn transfer_playback(generation: u64, to: &str) -> Result<(), CommandError> {
    require_session_connected(generation)?;
    // The service derives its source from this session. Use its device ID rather than the
    // cluster's possibly stale active ID. Copy both under the same owner and release the lock
    // before the upstream request.
    let session = with_engine_owned(generation, |engine| {
        engine
            .owns_resources()
            .then(|| {
                Some((
                    engine.session()?.clone(),
                    engine.connection.device_id.clone()?,
                ))
            })
            .flatten()
    })
    .ok()
    .flatten();
    let Some((session, from)) = session else {
        return Err(CommandError::NotConnected);
    };

    match block_on_playback(session.spclient().transfer(&from, to, None)) {
        Ok(Ok(_)) => {}
        Ok(Err(_)) => {
            debug!("Spotify rejected the transfer request");
            return Err(CommandError::Failed);
        }
        Err(error) => return Err(error),
    }

    let notification = with_current_generation_mutation(generation, || {
        let _ = with_engine_owned(generation, |engine| {
            // Pause via Spirc to keep its transport state ordered with the player command.
            if let Some(spirc) = engine.spirc() {
                let _ = spirc.pause();
            }
            engine.clear_playing();
        });
        store_active_device(false).then(|| capture_connection_state_notification(generation))
    });
    let Some(notification) = notification else {
        return Err(CommandError::NotConnected);
    };
    if let Some(notification) = notification {
        deliver_connection_state_notification(notification);
    }
    Ok(())
}

pub(crate) fn add_to_queue(generation: u64, uri: &str) -> Result<(), CommandError> {
    send_spirc_command(generation, "Add to queue", |spirc| {
        let uri = parse_spotify_uri(uri)
            .map_err(|_| librespot_core::Error::invalid_argument("Invalid queue URI"))?;
        spirc.add_to_queue(uri)
    })
}

pub(crate) fn current_spirc(what: &str) -> Option<Arc<Spirc>> {
    let spirc = current_spirc_handle();
    if spirc.is_none() {
        debug!("{} error: Spirc not initialized", what);
    }
    spirc
}

/// Logs a failed Spirc command against `what` using a sanitized command error.
///
/// A closed channel triggers a player rebuild. The log contains only the stable
/// classification; the upstream error can carry private response details and must not cross
/// this boundary through `Debug` formatting.
pub(crate) fn spirc_error(what: &str, err: &librespot_core::Error) -> CommandError {
    let category = match classify_spirc_command_failure(err) {
        SpircCommandFailure::CredentialRejected => "credential_rejected",
        SpircCommandFailure::NeedsReinit => "needs_reinit",
        SpircCommandFailure::Ordinary => "ordinary",
    };
    debug!("{} error: {}", what, category);
    classify_spirc_command_error(err)
}

/// Runs a command against the current Spirc and returns its typed result.
pub(crate) fn spirc_command(
    what: &str,
    command: impl FnOnce(&Spirc) -> Result<(), librespot_core::Error>,
) -> Result<(), CommandError> {
    let Some(spirc) = current_spirc(what) else {
        return Err(CommandError::Failed);
    };

    command(&spirc).map_err(|error| spirc_error(what, &error))
}
