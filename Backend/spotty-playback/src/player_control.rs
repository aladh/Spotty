use crate::*;

/// General command failure.
pub(crate) const ERROR_GENERAL: i32 = -1;
/// Closed command channel; the engine must be reinitialized.
pub(crate) const ERROR_NEEDS_REINIT: i32 = -2;
/// Session is not yet connected; the caller should wait for readiness.
pub(crate) const ERROR_NOT_CONNECTED: i32 = -3;
/// The cached streaming credentials were definitively rejected during initialization.
/// The account must authorize streaming again; this is not a reconnectable transport failure.
pub(crate) const ERROR_CREDENTIALS_REJECTED: i32 = -4;

/// Helper to check if session is connected. Returns ERROR_NOT_CONNECTED if not.
///
/// Also detects zombie sessions: the Session object may have been invalidated
/// (e.g. server closed the connection overnight) without the event listener
/// ever firing SessionDisconnected (because the Spirc task was idle).
/// When detected, updates state and triggers reconnection proactively.
pub(crate) fn require_session_connected() -> Result<(), i32> {
    if !with_connection(|c| c.session_connected) {
        debug!("Command rejected: session not connected");
        return Err(ERROR_NOT_CONNECTED);
    }

    let session_invalid = SESSION
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .as_ref()
        .is_none_or(|s| s.is_invalid());

    if session_invalid {
        debug!("Detected zombie session (is_connected=true but Session is invalid)");
        mark_disconnected("Session expired");
        spawn_reconnection_loop(RecoveryIntent::capture());
        return Err(ERROR_NOT_CONNECTED);
    }

    Ok(())
}

/// Plays multiple tracks in sequence.
///
/// # Parameters
/// - `track_uris_json`: JSON array of track URIs as a C string.
#[no_mangle]
pub extern "C" fn spotty_playback_play_tracks(
    track_uris_json: *const c_char,
) -> SpottyPlaybackResult {
    ffi_command("spotty_playback_play_tracks", || {
        debug!("spotty_playback_play_tracks called");
        if let Err(e) = require_session_connected() {
            return e;
        }
        let Some(track_uris_str) = (unsafe { c_string_arg(track_uris_json) }) else {
            debug!("Play tracks error: track_uris_json is null or not valid UTF-8");
            return -1;
        };

        // Parse JSON array of track URIs
        let track_uris: Vec<String> = match serde_json::from_str(&track_uris_str) {
            Ok(uris) => uris,
            Err(_e) => {
                debug!("Play tracks error: failed to parse JSON: {:?}", _e);
                return -1;
            }
        };

        if track_uris.is_empty() {
            debug!("Play tracks error: empty track URIs array");
            return -1;
        }

        // Use Spirc.load() for proper Connect state sync
        let Some(spirc) = current_spirc("Play tracks") else {
            return -1;
        };

        // Ensure device is active before loading
        if let Err(e) = ensure_active_for_playback(&spirc) {
            return e;
        }

        let load_request = LoadRequest::from_tracks(
            track_uris,
            LoadRequestOptions {
                start_playing: true,
                seek_to: 0,
                ..Default::default()
            },
        );
        match spirc.load(load_request) {
            Ok(_) => {
                debug!("Spirc.load(tracks) succeeded");
                set_active_device(true);
                0
            }
            Err(_e) => spirc_error("Play tracks", &_e),
        }
    })
}

/// Plays content by its Spotify URI or URL.
/// Supports albums, playlists, and artists (context URIs).
///
/// # Parameters
/// - `uri_or_url`: Spotify URI or URL (for example, "spotify:album:xxx").
#[no_mangle]
pub extern "C" fn spotty_playback_play_uri(uri_or_url: *const c_char) -> SpottyPlaybackResult {
    ffi_command("spotty_playback_play_uri", || {
        let Some(input_str) = (unsafe { c_string_arg(uri_or_url) }) else {
            debug!("Play error: uri_or_url is null or not valid UTF-8");
            return -1;
        };

        // Convert URL to URI if needed
        let uri_str = url_to_uri(&input_str);
        debug!("spotty_playback_play_uri called: uri={}", uri_str);

        if let Err(e) = require_session_connected() {
            return e;
        }

        // Use Spirc.load() with LoadRequest for proper Connect state sync
        let Some(spirc) = current_spirc("Play") else {
            return -1;
        };

        // Ensure device is active before loading
        if let Err(e) = ensure_active_for_playback(&spirc) {
            return e;
        }

        // Create LoadRequest - use from_context_uri for albums/playlists/artists,
        // from_tracks for a single track URI.
        let load_request = if uri_str.starts_with("spotify:track:") {
            debug!("Spirc.load(LoadRequest::from_tracks([{}]))", uri_str);
            LoadRequest::from_tracks(
                vec![uri_str.clone()],
                LoadRequestOptions {
                    start_playing: true,
                    seek_to: 0,
                    ..Default::default()
                },
            )
        } else {
            // Context-based playback from the beginning
            debug!("Spirc.load(LoadRequest::from_context_uri({}))", uri_str);
            LoadRequest::from_context_uri(
                uri_str.clone(),
                LoadRequestOptions {
                    start_playing: true,
                    seek_to: 0,
                    ..Default::default()
                },
            )
        };

        match spirc.load(load_request) {
            Ok(_) => {
                debug!("Spirc.load() succeeded");
                set_active_device(true);
                0
            }
            Err(_e) => spirc_error("Play", &_e),
        }
    })
}

/// Pauses playback. A successful pause publishes the accepted local paused snapshot so Swift
/// can stop display interpolation before the next player event.
#[no_mangle]
pub extern "C" fn spotty_playback_pause() -> SpottyPlaybackResult {
    ffi_command("spotty_playback_pause", pause_playback)
}

/// Resumes playback by activating the local device and issuing `play()`. If no Playing event
/// arrives, Swift issues seek-capable load fallbacks through [`spotty_playback_load`]. Reconnect
/// rehydration issues the same Swift targets while the connection snapshot reports
/// `resume_pending`.
#[no_mangle]
pub extern "C" fn spotty_playback_resume() -> SpottyPlaybackResult {
    ffi_command("spotty_playback_resume", resume_playback)
}

/// Loads a context or single track at `position_ms`.
///
/// `rehydrating_generation == 0` is a user-resume load: it waits briefly for a Playing event.
/// A nonzero value names the engine session generation being rehydrated after a reconnect: the
/// engine runs the load only if that generation is current and its `resume_pending` window is
/// still open, and returns 0 as soon as the load is queued (the window is the only Playing wait).
/// Otherwise it returns an ordinary failure without touching the session. Empty `track_hint` is
/// a valid context hint; `uri` must be non-empty.
///
/// # Parameters
/// - `uri`: Context or track URI.
/// - `track_hint`: Optional current-track hint for a context load.
/// - `from_context`: True for a context URI, false for a single track URI.
#[no_mangle]
pub extern "C" fn spotty_playback_load(
    uri: *const c_char,
    track_hint: SpottyNullableCString,
    position_ms: u32,
    from_context: bool,
    rehydrating_generation: u64,
) -> SpottyPlaybackResult {
    ffi_command("spotty_playback_load", || {
        let Some(uri) = (unsafe { c_string_arg(uri) }) else {
            return ERROR_GENERAL;
        };
        let track_hint = unsafe { c_string_arg(track_hint) };
        load_at_position(
            uri,
            track_hint,
            position_ms,
            from_context,
            rehydrating_generation,
        )
    })
}

/// Shuts down the Spirc connection and sends goodbye to other devices.
/// Call this when the app is quitting to properly disconnect from Spotify Connect.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotty_playback_shutdown() -> SpottyPlaybackResult {
    ffi_command("spotty_playback_shutdown", || {
        debug!("spotty_playback_shutdown called");
        // Prevent reconnection attempts during intentional shutdown
        SHUTTING_DOWN.store(true, Ordering::SeqCst);

        // The account is going away, so any streaming grant still waiting on a browser no longer
        // belongs to anyone. Only here — not in cleanup, which runs on every ordinary rebuild.
        LOGOUT_GENERATION.fetch_add(1, Ordering::SeqCst);

        // Publish the truth now rather than waiting for the listeners to notice the channel
        // close. A snapshot still claiming a connected session and a ready Spirc after an
        // intentional shutdown is what lets Swift adopt the dead session as a healthy one — on
        // logout that meant the next login skipped initialization and kept a closed Spirc.
        // Notified outside the lock: the callback re-enters Swift.
        with_connection(|c| {
            c.spirc_ready = false;
            c.session_connected = false;
            c.last_error = Some("Shutdown requested".to_string());
        });
        notify_connection_state_change();

        spirc_command("Shutdown", |spirc| spirc.shutdown())
    })
}

/// Disconnects from Spotify Connect without preventing future reconnection.
/// Use this before system sleep - the device disappears from Spotify immediately,
/// but forceReconnect() can still bring it back on wake.
/// Unlike shutdown(), this does NOT set SHUTTING_DOWN, so auto-reconnect still works.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotty_playback_disconnect() -> SpottyPlaybackResult {
    ffi_command("spotty_playback_disconnect", || {
        debug!("spotty_playback_disconnect called - disconnecting for sleep");
        // Set sleeping flag to prevent auto-reconnect when cluster listener ends
        SLEEPING.store(true, Ordering::SeqCst);

        let Some(spirc) = current_spirc("Disconnect") else {
            return -1;
        };

        // First pause playback to stop producing new audio
        let _ = spirc.pause();
        debug!("spotty_playback_disconnect: paused playback");

        // Clear the audio buffer synchronously to flush any remaining samples.
        // This must complete before we return, otherwise stale audio plays on wake — and it
        // blocks, which is the second reason `current_spirc` hands out a clone rather than a
        // guard.
        proxy_sink::ProxySink::clear_buffer();
        debug!("spotty_playback_disconnect: audio buffer cleared");

        // Now shutdown Spirc (disconnect from Spotify Connect)
        match spirc.shutdown() {
            Ok(()) => {
                debug!("spotty_playback_disconnect: spirc shutdown complete");
                0
            }
            Err(e) => spirc_error("Disconnect", &e),
        }
    })
}

/// Cleans up all player state, allowing a fresh reinitialization.
/// Call this before spotty_playback_init_player() when the session has disconnected.
/// This clears all static state (session, player, spirc, etc.)
#[no_mangle]
pub extern "C" fn spotty_playback_cleanup() {
    ffi_void("spotty_playback_cleanup", || {
        debug!("spotty_playback_cleanup called - clearing all state");

        // A callback from a Tokio worker cannot safely re-enter the process runtime. Refuse
        // before touching the generation: the old objects remain installed and can finish under
        // their owner, rather than leaving an invalidated but still-live generation behind.
        if refuse_if_nested_runtime().is_err() {
            debug!("spotty_playback_cleanup: refusing nested-runtime cleanup");
            return;
        }

        // Wait for an in-flight apply_cluster, then bump generation under the same gate
        // lock so mapping cannot begin for the outgoing session. A popped-not-yet-mapping
        // item is not waited on; begin_cluster_mapping re-checks after that gap.
        // Same-thread mapping (callback → cleanup) does not wait. The bump remains
        // before the lifecycle lock so an in-flight commit can observe supersession.
        let invalidated = invalidate_cluster_generation();
        debug!(
            "spotty_playback_cleanup invalidated generation, now {}",
            invalidated
        );

        match block_on_export(async {
            with_lifecycle_lock(async {
                cleanup_player_globals().await;
            })
            .await;
        }) {
            Ok(()) => {}
            Err(_) => {
                // The refusal above normally handles this. Keep this guard for a runtime
                // transition between the check and `block_on_export`; no unlocked writes are
                // safe while an in-flight build owns the lifecycle lock.
                debug!("spotty_playback_cleanup: refusing nested-runtime cleanup");
            }
        }
    })
}

/// Clears engine globals and session-scoped playback identity.
///
/// Callers that write these stores must already hold the lifecycle lock.
pub(crate) async fn cleanup_player_globals() {
    let _store = enter_store_section();
    teardown_engine_resources("spotty_playback_cleanup").await;

    // Reset state flags
    IS_PLAYING.store(false, Ordering::SeqCst);
    set_active_device(false);
    SHUFFLE_STATE.store(false, Ordering::SeqCst);
    REPEAT_TRACK_STATE.store(false, Ordering::SeqCst);
    REPEAT_CONTEXT_STATE.store(false, Ordering::SeqCst);
    POSITION_MS.store(0, Ordering::SeqCst);
    // Belongs to the session being torn down. Surviving a logout would let a resume seek to
    // an offset from the previous lifecycle, or another account's playback.
    RESUME_POSITION_MS.store(0, Ordering::SeqCst);
    // What that offset is an offset *into*, and the same argument applies with more at stake.
    // Resume loads use `CURRENT_CONTEXT_URI` with `CURRENT_TRACK_URI` as the track hint,
    // and nothing after a login rewrites them until playback establishes something new:
    // `update_current_context_uri` ignores empty values, and `set_current_track_uri` only runs
    // from player events. So pressing play as a freshly logged-in account reaches an activated
    // Spirc with no queue, `play()` produces no `Playing` event, and the fallback loads the
    // previous account's context — with its position, if this line's neighbour above had not
    // already been cleared. Reachable through the ordinary control path: with nobody active,
    // `sendTransportCommand` takes the Web API 404 and falls back to local
    // `spotty_playback_resume` plus Swift `ResumeLoadPlan` loads from these sticky URIs
    // (read through `spotty_playback_get_resume_*`). Reconnect rehydration issues the same
    // Swift targets while `build_player_async` publishes `resume_pending`.
    //
    // Only a full cleanup clears them. The wake and reconnect paths run
    // `do_reconnect_cleanup`, which deliberately leaves playback state alone so the
    // rehydrating load has something to reload; this function runs on logout and on an
    // explicit rebuild, after which Rust has no track or context loaded — which is what Swift
    // already assumes when `performInitialization` nils its own `currentTrackUri`.
    *CURRENT_TRACK_URI.lock().unwrap_or_else(|e| e.into_inner()) = None;
    *CURRENT_CONTEXT_URI
        .lock()
        .unwrap_or_else(|e| e.into_inner()) = None;
    // The cluster describes an account, so both of these belong to the session being torn
    // down. `spotty_playback_get_queue_snapshot` is what the queue bootstrap reads on a cold start,
    // and its whole guard rests on nil meaning "no cluster update has arrived" — a surviving
    // snapshot makes that read as "this is the queue", and a freshly logged-in account gets
    // the previous one's. The device list is a dedup cache, so a stale entry would suppress
    // the first update after a login as unchanged.
    *LAST_QUEUE.lock().unwrap_or_else(|e| e.into_inner()) = None;
    *LAST_DEVICES_FINGERPRINT
        .lock()
        .unwrap_or_else(|e| e.into_inner()) = None;
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

    debug!("spotty_playback_cleanup complete - ready for reinitialization");
}

/// Returns the last position reported by the Player.
///
/// Swift owns display interpolation. Interpolating here as well used to add up to five
/// seconds after Player events stopped, while reconnect rehydration correctly resumed from
/// this raw position. The two clocks therefore produced an exact five-second snap backwards.
pub(crate) fn current_position_ms() -> u32 {
    POSITION_MS.load(Ordering::SeqCst)
}

/// Returns the last position the Player reported, in milliseconds, or 0 if it has not reported
/// one. Deliberately not interpolated: Swift owns display interpolation.
#[no_mangle]
pub extern "C" fn spotty_playback_get_position_ms() -> u32 {
    ffi_query_u32("spotty_playback_get_position_ms", current_position_ms)
}

/// Returns the position saved at deactivation for a resume load, or 0 to use the live playhead.
#[no_mangle]
pub extern "C" fn spotty_playback_get_resume_position_ms() -> u32 {
    ffi_query_u32("spotty_playback_get_resume_position_ms", || {
        RESUME_POSITION_MS.load(Ordering::SeqCst)
    })
}

/// Returns the sticky resume-load context URI (`CURRENT_CONTEXT_URI`), or null if none.
/// The caller owns the returned string and frees it with `spotty_playback_free_string`.
/// An empty string is a present empty value.
#[no_mangle]
pub extern "C" fn spotty_playback_get_resume_context_uri() -> SpottyNullableMutCString {
    ffi_owned_string("spotty_playback_get_resume_context_uri", || {
        owned_optional_string(&CURRENT_CONTEXT_URI)
    })
}

/// Returns the sticky resume-load track URI (`CURRENT_TRACK_URI`), or null if none.
/// The caller owns the returned string and frees it with `spotty_playback_free_string`.
/// An empty string is a valid context hint.
#[no_mangle]
pub extern "C" fn spotty_playback_get_resume_track_uri() -> SpottyNullableMutCString {
    ffi_owned_string("spotty_playback_get_resume_track_uri", || {
        owned_optional_string(&CURRENT_TRACK_URI)
    })
}

fn owned_optional_string(slot: &Lazy<Mutex<Option<String>>>) -> *mut c_char {
    slot.lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
        .map_or(std::ptr::null_mut(), into_owned_c_string)
}

/// Skips to the next track in the queue.
/// Returns 0 on success, -1 on error, -2 if channel closed (needs reinit).
#[no_mangle]
pub extern "C" fn spotty_playback_next() -> SpottyPlaybackResult {
    ffi_command("spotty_playback_next", || {
        debug!("spotty_playback_next called");
        if let Err(e) = require_session_connected() {
            return e;
        }
        spirc_command("Next", |spirc| spirc.next())
    })
}

/// Skips to the previous track in the queue.
/// Returns 0 on success, -1 on error, -2 if channel closed (needs reinit).
#[no_mangle]
pub extern "C" fn spotty_playback_previous() -> SpottyPlaybackResult {
    ffi_command("spotty_playback_previous", || {
        debug!("spotty_playback_previous called");
        if let Err(e) = require_session_connected() {
            return e;
        }
        spirc_command("Previous", |spirc| spirc.prev())
    })
}

/// Seeks to the given position in milliseconds.
/// Returns 0 on success, -1 on error, -2 if channel closed (needs reinit).
#[no_mangle]
pub extern "C" fn spotty_playback_seek(position_ms: u32) -> SpottyPlaybackResult {
    ffi_command("spotty_playback_seek", || {
        debug!("spotty_playback_seek called: {}ms", position_ms);
        if let Err(e) = require_session_connected() {
            return e;
        }
        spirc_command("Seek", |spirc| spirc.set_position_ms(position_ms))
    })
}

/// Sets shuffle mode for the current playback context.
#[no_mangle]
pub extern "C" fn spotty_playback_set_shuffle(enabled: bool) -> SpottyPlaybackResult {
    ffi_command("spotty_playback_set_shuffle", || {
        debug!("spotty_playback_set_shuffle called: {}", enabled);
        if let Err(e) = require_session_connected() {
            return e;
        }
        spirc_command("Set shuffle", |spirc| spirc.shuffle(enabled))
    })
}

/// Repeats the current playback context (repeat the whole queue).
#[no_mangle]
pub extern "C" fn spotty_playback_set_repeat_context(enabled: bool) -> SpottyPlaybackResult {
    ffi_command("spotty_playback_set_repeat_context", || {
        debug!("spotty_playback_set_repeat_context called: {}", enabled);
        if let Err(e) = require_session_connected() {
            return e;
        }
        spirc_command("Set repeat context", |spirc| spirc.repeat(enabled))
    })
}

/// Repeats the current track (repeat one).
#[no_mangle]
pub extern "C" fn spotty_playback_set_repeat_track(enabled: bool) -> SpottyPlaybackResult {
    ffi_command("spotty_playback_set_repeat_track", || {
        debug!("spotty_playback_set_repeat_track called: {}", enabled);
        if let Err(e) = require_session_connected() {
            return e;
        }
        spirc_command("Set repeat track", |spirc| spirc.repeat_track(enabled))
    })
}

/// Sets the user-facing device name advertised to Spotify Connect. Must be called before
/// `spotty_playback_init_player` to affect the next Spirc instance. The string is copied during
/// this call.
#[no_mangle]
pub extern "C" fn spotty_playback_set_device_name(device_name: *const c_char) {
    ffi_void("spotty_playback_set_device_name", || {
        let Some(device_name) = (unsafe { c_string_arg(device_name) }) else {
            return;
        };
        let device_name = device_name.trim();
        if device_name.is_empty() {
            return;
        }
        *CONNECT_DEVICE_NAME_SETTING
            .lock()
            .unwrap_or_else(|e| e.into_inner()) = Some(device_name.to_string());
    })
}

/// Transfers playback from another device to this local player.
/// Uses the native Spotify Connect protocol via Spirc.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotty_playback_transfer_to_local() -> SpottyPlaybackResult {
    ffi_command("spotty_playback_transfer_to_local", || {
        debug!("spotty_playback_transfer_to_local called");
        if let Err(e) = require_session_connected() {
            return e;
        }
        // Pass None to transfer from whatever device is currently playing
        spirc_command("Transfer", |spirc| spirc.transfer(None))
    })
}

/// Transfers playback from this local player to another device using the native Spotify Connect
/// protocol via SpClient.
///
/// # Parameters
/// - `to_device_id`: The target device ID to transfer playback to.
#[no_mangle]
pub extern "C" fn spotty_playback_transfer_playback(
    to_device_id: *const c_char,
) -> SpottyPlaybackResult {
    ffi_command("spotty_playback_transfer_playback", || {
        let Some(to_device_str) = (unsafe { c_string_arg(to_device_id) }) else {
            debug!("Transfer playback error: to_device_id is null or not valid UTF-8");
            return -1;
        };

        debug!(
            "spotty_playback_transfer_playback called: {}",
            to_device_str
        );

        if let Err(e) = require_session_connected() {
            return e;
        }

        let session_guard = SESSION.lock().unwrap_or_else(|e| e.into_inner());
        let session = match session_guard.as_ref() {
            Some(s) => s.clone(),
            None => {
                debug!("Transfer playback error: session not initialized");
                return -1;
            }
        };
        drop(session_guard);

        // Deliberately our own device ID, not the cluster's active device. The endpoint is
        // POST /connect-state/v1/connect/transfer/from/{from}/to/{to}, and the backend derives
        // the source from the session rather than validating this segment: librespot itself
        // passes its own ID for *both* sides in the transfer-to-local path, in the branch that
        // only runs while it is not the active device (Spirc::handle_command, SpircCommand::
        // Transfer). Verified by hand too — Spotty -> iPhone -> a Connect speaker chains
        // fine, each hop sourced from an already-inactive Spotty.
        //
        // So passing the cluster's active device here would trade a value that is always known
        // for one that lags the dealer websocket by a few hundred milliseconds, and buy nothing.
        let from_device_id = match current_device_id() {
            Some(id) => id,
            None => {
                debug!("Transfer playback error: device ID not initialized");
                return -1;
            }
        };

        let result: Result<(), String> = match block_on_export(async {
            session
                .spclient()
                .transfer(&from_device_id, &to_device_str, None)
                .await
                .map_err(|e| format!("Transfer failed: {:?}", e))?;
            Ok(())
        }) {
            Ok(result) => result,
            Err(code) => return code,
        };

        match result {
            Ok(_) => {
                // Pause local playback after successful transfer. Cloned out of its global
                // first: with the Swift audio path in use `pause()` forwards into Swift, which
                // may call straight back into this crate, and no lock may be held across that.
                if let Some(player) = current_player() {
                    player.pause();
                }
                IS_PLAYING.store(false, Ordering::SeqCst);
                set_active_device(false);
                0
            }
            Err(_e) => {
                debug!("Transfer playback error: {}", _e);
                -1
            }
        }
    })
}

/// Adds a URI to the Connect queue.
///
/// The command forwards the string to Spirc as a single Spotify URI. Track URIs are the path
/// Spotty uses; this export does not resolve episodes, shows, or context URIs into a list of
/// tracks.
///
/// # Parameters
/// - `uri`: Spotify URI (for example, "spotify:track:xxx").
#[no_mangle]
pub extern "C" fn spotty_playback_add_to_queue(uri: *const c_char) -> SpottyPlaybackResult {
    ffi_command("spotty_playback_add_to_queue", || {
        let Some(uri_str) = (unsafe { c_string_arg(uri) }) else {
            debug!("Add to queue error: uri is null or not valid UTF-8");
            return -1;
        };

        debug!("[Spotty] spotty_playback_add_to_queue called: {}", uri_str);

        if let Err(e) = require_session_connected() {
            return e;
        }

        // Parse string to SpotifyUri
        let spotify_uri = match parse_spotify_uri(&uri_str) {
            Ok(uri) => uri,
            Err(e) => {
                debug!("Add to queue error: {}", e);
                return -1;
            }
        };

        spirc_command("Add to queue", |spirc| spirc.add_to_queue(spotify_uri))
    })
}
