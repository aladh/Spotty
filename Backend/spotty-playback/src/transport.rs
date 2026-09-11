use crate::*;

/// How often the playing-event waits re-read [`PlayingEventStamp`].
pub(crate) const PLAYING_EVENT_POLL_INTERVAL: Duration = Duration::from_millis(25);

/// How long `resume_playback` gives `Spirc::play` before Swift may issue load fallbacks.
/// `play` only queues a command, so this is the window in which an accepted one produces audio.
pub(crate) const PLAY_COMMAND_PLAYING_TIMEOUT: Duration = Duration::from_millis(500);

/// How long each seek-capable user-resume load waits for a Playing event before Swift may
/// try the next target. Inside a reconnect's rehydration window a load returns as soon as
/// it is queued; [`REHYDRATION_WINDOW`] is the only Playing wait there.
pub(crate) const RESUME_LOAD_PLAYING_TIMEOUT: Duration = Duration::from_secs(2);

/// How long a reconnect keeps readiness unpublished after publishing `resume_pending`: the
/// single Playing wait for Swift's queued rehydration load, sized as the previous engine-side
/// three-second wait plus Swift dispatch. A timeout gives up on the wait, not on the
/// session. Observed load-to-playing is around a second.
pub(crate) const REHYDRATION_WINDOW: Duration = Duration::from_secs(5);

/// Set by [`load_at_position`] when a load finds the Spirc command channel closed, so the
/// reconnect that opened the rehydration window can fail the build instead of announcing a
/// session that can never play. Reset when a window opens.
pub(crate) static REHYDRATION_NEEDS_REINIT: AtomicBool = AtomicBool::new(false);

/// Session generation that owns the open rehydration window. A load that started under an
/// older generation can still report its closed Spirc after a newer build has opened its own
/// window; that stale report must not fail the newer build.
pub(crate) static REHYDRATION_WINDOW_GENERATION: AtomicU64 = AtomicU64::new(0);

/// One seek-capable load target. Target *order* is the Swift `ResumeLoadPlan` policy for
/// user resume and reconnect rehydration alike; this crate only turns one target into a
/// `LoadRequest`. Context carries an optional current-track hint; a single-track load has
/// none.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ResumeLoadTarget {
    Context {
        uri: String,
        track_hint: Option<String>,
        position_ms: u32,
    },
    Track {
        uri: String,
        position_ms: u32,
    },
}

impl ResumeLoadTarget {
    /// Logs this fallback and builds the Spirc load. [`load_at_position`] only issues the
    /// request; start-playing, seek, track-hint, and the diagnostic wording live here so they
    /// cannot drift between targets.
    fn into_load(self) -> (LoadRequest, &'static str) {
        match self {
            Self::Context {
                uri,
                track_hint,
                position_ms,
            } => {
                let playing_track = track_hint.map(PlayingTrack::Uri);
                debug!(
                    "Resume fallback: loading context {} at {}ms (track hint: {:?})",
                    uri, position_ms, playing_track
                );
                (
                    LoadRequest::from_context_uri(
                        uri,
                        LoadRequestOptions {
                            start_playing: true,
                            seek_to: position_ms,
                            playing_track,
                            ..Default::default()
                        },
                    ),
                    "Resume fallback context load",
                )
            }
            Self::Track { uri, position_ms } => {
                debug!(
                    "Resume fallback: loading single track {} at {}ms",
                    uri, position_ms
                );
                (
                    LoadRequest::from_tracks(
                        vec![uri],
                        LoadRequestOptions {
                            start_playing: true,
                            seek_to: position_ms,
                            ..Default::default()
                        },
                    ),
                    "Resume fallback track load",
                )
            }
        }
    }
}

fn nonempty_uri(uri: Option<String>) -> Option<String> {
    uri.filter(|uri| !uri.is_empty())
}

/// Whether the sticky session globals hold anything a resume load could reload.
///
/// This is the only resume-load fact the reconnect path reads for itself: with neither a
/// context nor a track URI, Swift's `ResumeLoadPlan` has no targets and opening a
/// rehydration window would only delay readiness. Empty strings are missing, exactly as
/// Swift's plan treats them. Target order stays Swift-owned.
pub(crate) fn has_resume_identity() -> bool {
    let context = CURRENT_CONTEXT_URI
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone();
    let track = CURRENT_TRACK_URI
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone();
    nonempty_uri(context).is_some() || nonempty_uri(track).is_some()
}

/// How a rehydration window closed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RehydrationOutcome {
    /// The Player of the generation that opened the window reported playback: a Swift load
    /// landed. A Playing event stamped with another generation does not count.
    Playing,
    /// A Swift load found the Spirc command channel closed; the build must fail.
    NeedsReinit,
    /// Nothing landed in time. Not fatal: a load may still arrive, and tearing down an
    /// otherwise healthy session would be worse than announcing it late.
    TimedOut,
}

/// Opens a rehydration window for `generation`: records the owner, clears the reinit flag,
/// and returns the playing-event sequence to wait past. Call before publishing
/// `resume_pending` to Swift.
#[cfg(test)]
pub(crate) fn open_rehydration_window(generation: u64) -> u64 {
    with_generation_mutation(|| open_rehydration_window_locked(generation))
}

/// Opens a rehydration window while the caller already owns the generation mutation gate.
pub(crate) fn open_rehydration_window_locked(generation: u64) -> u64 {
    REHYDRATION_WINDOW_GENERATION.store(generation, Ordering::SeqCst);
    REHYDRATION_NEEDS_REINIT.store(false, Ordering::SeqCst);
    playing_event_stamp().sequence
}

/// Whether a rehydration load naming `generation` may run right now: that generation is the
/// current session, and its rehydration window is still open. Evaluated in the engine, on the
/// calling thread, immediately before the load, so Swift's own pre-checks are an early-out
/// rather than the guarantee.
pub(crate) fn rehydration_load_is_current(generation: u64) -> bool {
    SESSION_GENERATION.load(Ordering::SeqCst) == generation
        && REHYDRATION_WINDOW_GENERATION.load(Ordering::SeqCst) == generation
        && with_connection(|c| c.resume_pending)
}

/// Records a closed-channel load result for the window it belongs to. A load stamped with a
/// generation other than the open window's owner is stale and is ignored here (its caller
/// still sees `ERROR_NEEDS_REINIT`).
pub(crate) fn note_load_needs_reinit(load_generation: u64) {
    with_generation_mutation(|| note_load_needs_reinit_locked(load_generation));
}

/// Records a closed-channel result while the caller already owns the generation mutation gate.
fn note_load_needs_reinit_locked(load_generation: u64) {
    if REHYDRATION_WINDOW_GENERATION.load(Ordering::SeqCst) == load_generation {
        REHYDRATION_NEEDS_REINIT.store(true, Ordering::SeqCst);
    }
}

/// Whether one coherently published Playing event is newer than the window and came from the
/// pump that owns it. Reading a single stamp prevents an old sequence from being paired with a
/// newer generation while an event listener is publishing.
fn playing_event_belongs_to_window(previous_seq: u64) -> bool {
    let stamp = playing_event_stamp();
    stamp.sequence > previous_seq
        && stamp.generation == REHYDRATION_WINDOW_GENERATION.load(Ordering::SeqCst)
}

/// Waits inside the runtime for a Swift rehydration load to land, fail terminally, or time
/// out, without parking a tokio worker. A sequence advance from a superseded generation's
/// pump is ignored; only the window's own generation can close it as `Playing`.
pub(crate) async fn wait_for_rehydration(
    previous_seq: u64,
    timeout: Duration,
) -> RehydrationOutcome {
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        if playing_event_belongs_to_window(previous_seq) {
            return RehydrationOutcome::Playing;
        }
        if REHYDRATION_NEEDS_REINIT.load(Ordering::SeqCst) {
            return RehydrationOutcome::NeedsReinit;
        }
        if tokio::time::Instant::now() >= deadline {
            return RehydrationOutcome::TimedOut;
        }
        tokio::time::sleep(PLAYING_EVENT_POLL_INTERVAL).await;
    }
}

/// Helper to ensure the device is active before loading content.
/// If not active, activates via Spirc directly (no spclient HTTP needed).
/// Returns Ok(()) if ready to load, Err(i32) with error code if activation failed.
pub(crate) fn ensure_active_for_playback(spirc: &Arc<Spirc>) -> Result<(), i32> {
    if !is_active_device() {
        debug!("Device not active, activating via spirc.activate()");
        match spirc.activate() {
            Ok(_) => {
                debug!("Activate succeeded");
                set_active_device(true);
            }
            Err(error) => return Err(spirc_error("Activate", &error)),
        }
    }
    Ok(())
}

/// Whether the Playing-event sequence has advanced past the value captured before a command.
pub(crate) fn playing_event_advanced(previous_seq: u64) -> bool {
    playing_event_stamp().sequence > previous_seq
}

/// Waits for the Player to report playback, blocking the calling thread.
///
/// For the synchronous FFI entry points, which are called on Swift's own threads. Inside the
/// runtime use the async twin below instead.
pub(crate) fn wait_for_playing_event(previous_seq: u64, timeout: Duration) -> bool {
    let deadline = std::time::Instant::now() + timeout;
    loop {
        if playing_event_advanced(previous_seq) {
            return true;
        }
        if std::time::Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(PLAYING_EVENT_POLL_INTERVAL);
    }
}

/// Queues one `LoadRequest`. `None` means try the next fallback; a closed channel is terminal.
pub(crate) fn issue_load_target(spirc: &Spirc, target: ResumeLoadTarget) -> Option<i32> {
    let (load_request, what) = target.into_load();
    match spirc.load(load_request) {
        Ok(_) => Some(0),
        Err(e) => match spirc_error(what, &e) {
            ERROR_NEEDS_REINIT => Some(ERROR_NEEDS_REINIT),
            _ => None,
        },
    }
}

/// One seek-capable load for Swift `ResumeLoadPlan` targets, for user resume and for
/// reconnect rehydration alike.
///
/// `rehydrating_generation == 0` is a user-resume load: each target is given the resume-load
/// playing timeout, and a timeout lets Swift try the next fallback. A nonzero value names the
/// engine session generation Swift is rehydrating. The engine is the enforcement point for
/// that token: the load runs only if that generation is current and its rehydration window
/// is still open, so a rehydration queued behind another command in Swift cannot land in a
/// later session or after the window closed. A rehydration load returns `0` as soon as Spirc
/// queued it: the reconnect's window is the one Playing wait, and a queued context load must
/// not be superseded by a single-track fallback merely because a cold session took longer
/// than the per-target timeout to start.
///
/// `Spirc::load` only hands the command to a channel, so `Ok` means "queued", not
/// "accepted", and `SpircTask` drops `Load` while its connect state is inactive. Activity is
/// therefore established by `ensure_active_for_playback` here (or by `build_player_async`
/// before it publishes `resume_pending`), never inferred from a queued command. This used to
/// be inferred, which turned a discarded load into an apparent takeover: Swift believed
/// Spotty was the active device and routed every later command to a player ignoring them.
pub(crate) fn load_at_position(
    uri: String,
    track_hint: Option<String>,
    position_ms: u32,
    from_context: bool,
    rehydrating_generation: u64,
) -> i32 {
    if uri.is_empty() {
        return ERROR_GENERAL;
    }
    let rehydrating = rehydrating_generation != 0;
    if rehydrating && !rehydration_load_is_current(rehydrating_generation) {
        debug!(
            "Rehydration load for generation {} declined: window closed or session moved on",
            rehydrating_generation
        );
        return ERROR_GENERAL;
    }
    if let Err(e) = require_session_connected() {
        return e;
    }
    // Stamped before the Spirc handle is taken, so a closed channel found below is attributed
    // to the generation this load actually ran against.
    let load_generation = if rehydrating {
        rehydrating_generation
    } else {
        SESSION_GENERATION.load(Ordering::SeqCst)
    };
    let Some(spirc) = current_spirc("Load") else {
        return ERROR_GENERAL;
    };
    if !rehydrating {
        if let Err(e) = ensure_active_for_playback(&spirc) {
            return e;
        }
    }
    let target = if from_context {
        ResumeLoadTarget::Context {
            uri,
            track_hint,
            position_ms,
        }
    } else {
        ResumeLoadTarget::Track { uri, position_ms }
    };
    let seq_before = playing_event_stamp().sequence;
    let issue_result = if rehydrating {
        // `ensure_active_for_playback` above may have re-entered Swift and allowed teardown to
        // start. Revalidate generation/window ownership and the concrete Spirc immediately before
        // sending the command. The short synchronous gate excludes the generation invalidation
        // point for the send itself; it never spans a callback or an await.
        let Some(result) = with_current_generation_mutation(rehydrating_generation, || {
            if !rehydration_load_is_current(rehydrating_generation) {
                return Err(ERROR_GENERAL);
            }
            let Some(current_spirc) = current_spirc("Load") else {
                return Err(ERROR_GENERAL);
            };
            if !Arc::ptr_eq(&spirc, &current_spirc) {
                return Err(ERROR_GENERAL);
            }
            if !is_active_device() {
                return Err(ERROR_NOT_CONNECTED);
            }
            let result = issue_load_target(&spirc, target);
            if result == Some(ERROR_NEEDS_REINIT) {
                note_load_needs_reinit_locked(load_generation);
            }
            Ok(result)
        }) else {
            return ERROR_GENERAL;
        };
        match result {
            Ok(result) => result,
            Err(error) => return error,
        }
    } else {
        issue_load_target(&spirc, target)
    };

    match issue_result {
        Some(0) => {
            if rehydrating {
                debug!("Rehydration load queued; the reconnect window waits for Playing");
                0
            } else if wait_for_playing_event(seq_before, RESUME_LOAD_PLAYING_TIMEOUT) {
                0
            } else {
                ERROR_GENERAL
            }
        }
        Some(ERROR_NEEDS_REINIT) => {
            // Reported to the caller as usual, and also to a reconnect that may be holding
            // readiness open for this very load: its Spirc is already dead.
            if !rehydrating {
                note_load_needs_reinit(load_generation);
            }
            ERROR_NEEDS_REINIT
        }
        Some(code) => code,
        None => ERROR_GENERAL,
    }
}

/// Publishes the accepted local pause so Swift does not keep interpolating time.
///
/// The playing flag is cleared here rather than left to the event stream: the user can pause
/// while a track is still loading, and in that case `PlayerEvent::Playing` never fires, so
/// there is no playing-to-paused transition for the listener to report. A locally issued
/// pause is also not guaranteed to produce `PlayerEvent::Paused` (for example while the
/// player is still transitioning between tracks). A later player or cluster update remains
/// authoritative and can correct this snapshot if the command did not land.
pub(crate) fn publish_accepted_local_pause() {
    clear_engine_playing();
    send_local_playback_state(false, POSITION_MS.load(Ordering::SeqCst));
}

/// Pauses playback through Spirc and publishes the accepted local paused snapshot.
pub(crate) fn pause_playback() -> i32 {
    debug!("spotty_playback_pause called");
    if let Err(e) = require_session_connected() {
        return e;
    }
    spirc_command("Pause", |spirc| {
        spirc.pause()?;
        publish_accepted_local_pause();
        Ok(())
    })
}

/// Resumes playback: activate, `play()`, then return so Swift can issue seek-capable
/// load fallbacks. Reconnect rehydration uses the same Swift targets through
/// [`load_at_position`] while `build_player_async` holds readiness open.
pub(crate) fn resume_playback() -> i32 {
    debug!("spotty_playback_resume called");
    if let Err(e) = require_session_connected() {
        return e;
    }

    // Read the playing flag and claim the resume slot together. Separately, a Playing event
    // landing between the two let a second resume claim the slot and restart the track.
    // A resume already working is what this caller wanted, so joining it reports success
    // rather than starting a second one.
    enum ResumeClaim {
        AlreadyPlaying,
        AlreadyResuming,
        Claimed,
    }
    let claim = with_engine(|engine| {
        if engine.is_playing() {
            ResumeClaim::AlreadyPlaying
        } else if engine.claim_resume() {
            ResumeClaim::Claimed
        } else {
            ResumeClaim::AlreadyResuming
        }
    });
    match claim {
        ResumeClaim::AlreadyPlaying => return 0,
        ResumeClaim::AlreadyResuming => {
            debug!("Resume already in progress");
            return 0;
        }
        ResumeClaim::Claimed => {}
    }
    let _resuming = ResumeGuard;

    let Some(spirc) = current_spirc("Resume") else {
        return ERROR_GENERAL;
    };

    // Activation is a precondition, not an optimization. `SpircTask` matches
    // `_ if !self.connect_state.is_active()` ahead of every transport command, so `Play`,
    // `Load`, `Next`, `Prev`, `Shuffle` and `SetPosition` are discarded with a warning while
    // inactive — the whole resume path below, load fallback included, would be dropped and
    // nothing would play. Waking from sleep lands here every time: the sleep teardown shuts
    // Spirc down, librespot answers with `SessionDisconnected`, and its handler clears the
    // active flag.
    if let Err(e) = ensure_active_for_playback(&spirc) {
        return e;
    }

    let play_seq_before = playing_event_stamp().sequence;
    if let Err(e) = spirc.play() {
        return spirc_error("Resume", &e);
    }

    if wait_for_playing_event(play_seq_before, PLAY_COMMAND_PLAYING_TIMEOUT) {
        return 0;
    }

    debug!("Resume play() produced no Playing event within timeout; Swift may load fallbacks");
    ERROR_GENERAL
}
