use crate::*;
use std::collections::HashMap;

// Player state. The retained engine has one production player implementation: librespot's own
// `Player`, which decodes in-process and delivers bounded PCM through `proxy_sink`.
pub(crate) static PLAYER: Lazy<Mutex<Option<Arc<Player>>>> = Lazy::new(|| Mutex::new(None));

/// Join handles for every task created for the current engine generation.
///
/// Keeping the handles together makes teardown an owned operation: a failed build can cancel all
/// work it started, and a normal generation replacement can await the old tasks before dropping
/// the objects they retain. The vector is taken before cancellation, so no task is ever awaited
/// while holding the global registry lock.
pub(crate) static ENGINE_TASKS: Lazy<Mutex<Option<Vec<JoinHandle<()>>>>> =
    Lazy::new(|| Mutex::new(None));
pub(crate) static SESSION: Lazy<Mutex<Option<Session>>> = Lazy::new(|| Mutex::new(None));
pub(crate) static MIXER: Lazy<Mutex<Option<Arc<SoftMixer>>>> = Lazy::new(|| Mutex::new(None));
pub(crate) static SPIRC: Lazy<Mutex<Option<Arc<Spirc>>>> = Lazy::new(|| Mutex::new(None));

/// Returns the current concrete librespot Player without holding its registry lock.
pub(crate) fn current_player() -> Option<Arc<Player>> {
    PLAYER.lock().unwrap_or_else(|e| e.into_inner()).clone()
}
/// Local playing flag. `true` only after `PlayerEvent::Playing`. `Spirc::load`
/// `Ok` means the command was queued, not that audio started, so the play
/// commands must not store `true` here: `resume_playback` returns success
/// without issuing play or its fallback whenever this flag is already set.
pub(crate) static IS_PLAYING: AtomicBool = AtomicBool::new(false);

/// One `PlayerEvent::Playing` publication.
///
/// The sequence gives ordinary play/load waits an edge to wait past. Reconnect rehydration
/// additionally needs the listener generation that produced that exact edge. Keep both facts
/// behind one mutex: separate atomics can be read as a record that was never published (for
/// example, an old sequence paired with a newly written generation).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct PlayingEventStamp {
    pub(crate) generation: u64,
    pub(crate) sequence: u64,
}

pub(crate) static PLAYING_EVENT_STAMP: Lazy<Mutex<PlayingEventStamp>> =
    Lazy::new(|| Mutex::new(PlayingEventStamp::default()));

/// Publishes a Playing event as one coherent `(generation, sequence)` record.
pub(crate) fn publish_playing_event(generation: u64) -> PlayingEventStamp {
    let mut stamp = PLAYING_EVENT_STAMP
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    stamp.generation = generation;
    stamp.sequence = stamp.sequence.wrapping_add(1);
    *stamp
}

/// Reads the last Playing event's generation and sequence as one record.
pub(crate) fn playing_event_stamp() -> PlayingEventStamp {
    *PLAYING_EVENT_STAMP
        .lock()
        .unwrap_or_else(|error| error.into_inner())
}

#[cfg(test)]
pub(crate) fn replace_playing_event_stamp_for_test(stamp: PlayingEventStamp) {
    *PLAYING_EVENT_STAMP
        .lock()
        .unwrap_or_else(|error| error.into_inner()) = stamp;
}

/// Set while a `spotty_playback_resume` is working, so only one runs at a time.
///
/// Resuming is not instantaneous: `Spirc::play` only queues a command, then this export
/// waits briefly for a `Playing` event. Swift `RustPlaybackEngine` then iterates
/// `ResumeLoadPlan` targets through `spotty_playback_load` (reconnect rehydration issues the
/// same targets inside `build_player_async`'s window). `PlaybackCoordinator`
/// serializes that whole `execute(.resume)` so the app path does not stack play-then-load.
/// This flag still covers overlapping C `spotty_playback_resume` calls. `IS_PLAYING` does
/// not cover the gap: it stays false until the first sequence actually produces audio.
pub(crate) static RESUMING: AtomicBool = AtomicBool::new(false);

/// Clears [`RESUMING`] however `spotty_playback_resume` returns.
pub(crate) struct ResumeGuard;

impl Drop for ResumeGuard {
    fn drop(&mut self) {
        RESUMING.store(false, Ordering::SeqCst);
    }
}
pub(crate) static PLAYER_EVENT_TX: Lazy<Mutex<Option<mpsc::UnboundedSender<()>>>> =
    Lazy::new(|| Mutex::new(None));

/// Process-lifetime control callback registry.
///
/// Each slot keeps an independent lock, so a callback on one event stream cannot block another.
/// Call sites always copy the function pointer and release its slot before entering Swift. PCM
/// and audio-control callbacks remain in `proxy_sink`: the real-time audio path does not touch
/// this registry or any of these locks.
#[derive(Default)]
pub(crate) struct ControlCallbacks {
    pub(crate) queue: Mutex<Option<QueueSnapshotCallback>>,
    pub(crate) playback_state: Mutex<Option<PlaybackSnapshotCallback>>,
    pub(crate) devices: Mutex<Option<DevicesSnapshotCallback>>,
    pub(crate) connection_state: Mutex<Option<ConnectionSnapshotCallback>>,
}

pub(crate) static CONTROL_CALLBACKS: Lazy<ControlCallbacks> = Lazy::new(ControlCallbacks::default);
/// Fingerprint of the last `(active_device_id, protocol members)` sent to Swift, so an
/// unchanged cluster update stays silent. Cluster updates arrive for every playback tick,
/// and the device list changes far more rarely. Activity changes still fire because the
/// active id is part of the fingerprint.
#[derive(Clone, PartialEq, Eq)]
pub(crate) struct DevicesFingerprint {
    pub(crate) active_device_id: String,
    pub(crate) devices: Vec<ProtocolConnectDevice>,
}

pub(crate) static LAST_DEVICES_FINGERPRINT: Lazy<Mutex<Option<DevicesFingerprint>>> =
    Lazy::new(|| Mutex::new(None));
/// The last queue the cluster described, so Swift can ask again rather than re-deriving it
/// from the Web API. See `spotty_playback_get_queue_snapshot`.
pub(crate) static LAST_QUEUE: Lazy<Mutex<Option<QueueState>>> = Lazy::new(|| Mutex::new(None));
/// Serializes snapshot building so a revision always orders snapshots by the state they
/// actually saw. Held only across the build, never across delivery into Swift.
pub(crate) static SNAPSHOT_REVISION: Mutex<u64> = Mutex::new(0);

/// Ordering metadata shared by every structured control snapshot sent over the C boundary.
///
/// `revision` is process-monotonic, while `session_generation` identifies the engine instance
/// whose state was observed. Swift can therefore reject both a late callback and a callback from
/// a session that has already been replaced.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct SnapshotStamp {
    pub(crate) revision: u64,
    pub(crate) session_generation: u64,
}

/// Builds a value while owning the revision lock, preserving creation order across connection,
/// playback, and queue snapshots. Callback delivery remains outside this function so no Swift
/// re-entry occurs while the lock is held.
pub(crate) fn stamped_snapshot<T>(build: impl FnOnce(SnapshotStamp) -> T) -> T {
    let mut revision = SNAPSHOT_REVISION.lock().unwrap_or_else(|e| e.into_inner());
    *revision = revision.saturating_add(1);
    build(SnapshotStamp {
        revision: *revision,
        session_generation: SESSION_GENERATION.load(Ordering::SeqCst),
    })
}

/// Builds a snapshot revision for an explicitly owned engine generation.
///
/// Most publishers observe the current generation at the point they assemble their payload.
/// A generation-scoped event publisher may have to release its short mutation gate before it
/// enters Swift, though; using this helper keeps that callback stamped with the generation whose
/// state produced it instead of whichever generation happened to be current at delivery time.
pub(crate) fn stamped_snapshot_for_generation<T>(
    session_generation: u64,
    build: impl FnOnce(SnapshotStamp) -> T,
) -> T {
    let mut revision = SNAPSHOT_REVISION.lock().unwrap_or_else(|e| e.into_inner());
    *revision = revision.saturating_add(1);
    build(SnapshotStamp {
        revision: *revision,
        session_generation,
    })
}
pub(crate) static SHUFFLE_STATE: AtomicBool = AtomicBool::new(false);
pub(crate) static REPEAT_TRACK_STATE: AtomicBool = AtomicBool::new(false);
pub(crate) static REPEAT_CONTEXT_STATE: AtomicBool = AtomicBool::new(false);

// Flag to track if reconnection is in progress
pub(crate) static RECONNECTING: AtomicBool = AtomicBool::new(false);
// Flag to track intentional shutdown (prevents reconnection attempts during app quit)
pub(crate) static SHUTTING_DOWN: AtomicBool = AtomicBool::new(false);
// Flag to track sleep state (prevents auto-reconnect, but allows explicit forceReconnect on wake)
pub(crate) static SLEEPING: AtomicBool = AtomicBool::new(false);

/// Everything the engine's connection observation is assembled from, behind a single lock.
///
/// These fields used to live in six independent globals (three mutexes and three
/// atomics), so a snapshot assembled from them could mix values from different
/// transitions — ready from one, connection metadata from another. Keeping them
/// together makes every published snapshot internally consistent by construction.
///
/// `is_active_device` also lives here rather than in a separate atomic. It used to be
/// tracked in `IS_ACTIVE_DEVICE`, written from fourteen scattered command and event sites
/// and never reconciled against the cluster, while Swift separately tracked activity from
/// the active-device-id callback — so playback routing and the UI could disagree about
/// whether Spotty or a remote speaker was active.
#[derive(Default, Clone)]
pub(crate) struct ConnectionState {
    pub(crate) session_connected: bool,
    pub(crate) spirc_ready: bool,
    pub(crate) device_id: Option<String>,
    pub(crate) last_error: Option<String>,
    /// The cached AP credential was definitively rejected by Spotify. This is a typed
    /// connection outcome; it is kept separate from the sanitized human-readable status so
    /// Swift can offer reauthentication without parsing an upstream error string.
    pub(crate) credentials_rejected: bool,
    pub(crate) is_active_device: bool,
    /// True only inside a reconnect's rehydration window: the session is connected and
    /// activated, readiness is deliberately unpublished, and Swift should issue its
    /// `ResumeLoadPlan` targets now. Cleared when readiness commits or on cleanup.
    pub(crate) resume_pending: bool,
}

/// Records a definitive credential rejection and publishes it as a typed connection outcome.
///
/// `last_error` remains a stable, privacy-safe category. It never contains the upstream error,
/// access token, or any response payload. A newer generation clears the flag when it begins.
pub(crate) fn mark_credentials_rejected() {
    with_connection(|c| {
        c.session_connected = false;
        c.spirc_ready = false;
        c.resume_pending = false;
        c.credentials_rejected = true;
        c.last_error = Some("Spotify credentials rejected".to_string());
    });
    notify_connection_state_change();
}

/// Whether this engine's device is the cluster's active member.
///
/// Presentation of the device *list* uses the same rule in Swift
/// (`ConnectDeviceProjection.isActive`). An empty active-device ID means nothing is
/// active anywhere and must clear activity rather than be ignored.
pub(crate) fn is_active_in_cluster(active_device_id: &str, own_device_id: Option<&str>) -> bool {
    !active_device_id.is_empty() && own_device_id == Some(active_device_id)
}

/// Whether an intentional teardown is under way. Recovery must never fight one.
pub(crate) fn teardown_in_progress() -> bool {
    SHUTTING_DOWN.load(Ordering::SeqCst) || SLEEPING.load(Ordering::SeqCst)
}

/// Whether losing the active Connect role should start network recovery.
///
/// Deactivation is normally just a handoff to another device and must not reconnect. The
/// one case that must is a Session that has gone invalid: librespot calls
/// `handle_disconnect` on unexpected Spirc shutdown, and the cluster listener can miss
/// that while the dealer stream is still open.
pub(crate) fn should_recover_after_deactivation(
    session_invalid: bool,
    teardown_in_progress: bool,
) -> bool {
    session_invalid && !teardown_in_progress
}

/// What playback looked like when recovery was decided on.
///
/// Captured at the trigger rather than inside the reconnect task. Between those two points
/// the deactivation handler clears the active flag, a `Stopped` event clears `IS_PLAYING`,
/// and a final cluster update can clear both — so reading it late made "does an outage
/// resume playback" depend on event ordering rather than on what was actually playing.
/// The recovering session generation is captured the same way; see `start_reconnect_loop`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct RecoveryIntent {
    pub(crate) was_playing: bool,
    pub(crate) was_active: bool,
}

impl RecoveryIntent {
    /// Reads what is playing right now. Call this before touching playback state.
    pub(crate) fn capture() -> Self {
        Self {
            was_playing: IS_PLAYING.load(Ordering::SeqCst),
            was_active: is_active_device(),
        }
    }

    /// Only local playback is rehydrated. If another device was playing, it still is, and
    /// taking over would steal it from the user.
    pub(crate) fn should_resume(self) -> bool {
        self.was_playing && self.was_active
    }
}

/// Whether the periodic health check should start recovery.
///
/// Invalidity alone is not a sufficient trigger. `Session::is_invalid` is only set by
/// `shutdown()`, so a session that was created but never managed to connect — exactly what
/// a failed `build_player_async` leaves behind — reports itself valid forever. The state
/// that actually needs rescuing is "not connected and nobody is recovering", however it was
/// reached: a session that died, or one that never came up.
///
/// The reconnect check matters because the loop is the thing that fixes this; firing while
/// it is already running would only re-publish a disconnected snapshot once a minute.
pub(crate) fn health_check_should_recover(
    session_invalid: bool,
    session_connected: bool,
    reconnect_in_progress: bool,
    teardown_in_progress: bool,
) -> bool {
    !teardown_in_progress && !reconnect_in_progress && (session_invalid || !session_connected)
}

/// Whether a listener may act on an event, given the generation it was created for.
///
/// A superseded listener drains asynchronously after its replacement is installed, so it
/// can still deliver events belonging to a session that no longer exists.
pub(crate) fn listener_may_act(listener_generation: u64, current_generation: u64) -> bool {
    listener_generation == current_generation
}

/// Whether a reconnect loop may still rebuild, given the generation it set out to recover.
///
/// The loop sleeps up to 30 seconds between attempts. A manual restart or a teardown in
/// that window means the thing it is fixing is gone, and rebuilding would clobber whatever
/// replaced it.
pub(crate) fn reconnect_may_proceed(
    recovering_generation: u64,
    current_generation: u64,
    teardown_in_progress: bool,
) -> bool {
    recovering_generation == current_generation && !teardown_in_progress
}

/// Whether a cluster listener that ended should start network recovery.
///
/// Only the listener belonging to the current session generation may act. An older
/// listener ending is the expected consequence of the session it belonged to being
/// replaced, not evidence of a transport failure — acting on it would reconnect a session
/// that is already healthy.
pub(crate) fn should_recover_after_cluster_end(
    listener_generation: u64,
    current_generation: u64,
    teardown_in_progress: bool,
) -> bool {
    listener_generation == current_generation && !teardown_in_progress
}

/// Whether this device is currently the active Spotify Connect device.
pub(crate) fn is_active_device() -> bool {
    with_connection(|c| c.is_active_device)
}

/// Records whether this device is the active one, publishing the change if it moved.
pub(crate) fn set_active_device(active: bool) {
    if store_active_device(active) {
        notify_connection_state_change();
    }
}

/// Records activity without publishing, returning whether it changed.
///
/// For callers that are mid-transition and will publish once when they are done —
/// `build_player_async` still has to rehydrate after activating, and publishing in between
/// is what let Swift bootstrap against a half-built session.
pub(crate) fn store_active_device(active: bool) -> bool {
    let changed = with_connection(|c| {
        let changed = c.is_active_device != active;
        c.is_active_device = active;
        changed
    });
    if changed {
        debug!("Active device changed: is_active={}", active);
    }
    changed
}

pub(crate) static CONNECTION: Lazy<Mutex<ConnectionState>> =
    Lazy::new(|| Mutex::new(ConnectionState::default()));

/// Mutates the connection state under its lock and returns whatever `f` returns.
///
/// Does not publish — callers decide when to `notify_connection_state_change()`, so a
/// multi-field transition emits one snapshot rather than one per field. Never call
/// `notify_connection_state_change()` from inside `f`: it locks `CONNECTION` too.
pub(crate) fn with_connection<R>(f: impl FnOnce(&mut ConnectionState) -> R) -> R {
    let mut state = CONNECTION.lock().unwrap_or_else(|e| e.into_inner());
    f(&mut state)
}

/// Returns the device ID assigned at session creation, if a session has been built.
pub(crate) fn current_device_id() -> Option<String> {
    with_connection(|c| c.device_id.clone())
}

// Position tracking - updated from player events
pub(crate) static POSITION_MS: AtomicU32 = AtomicU32::new(0);

/// Where playback should pick up after a deactivation, or 0 when there is nothing to
/// recover.
///
/// `POSITION_MS` cannot serve this on its own. librespot stops the Player when the device
/// is deactivated, and the `Stopped` event that follows must reset the live position —
/// `handle_stop` fires for a queue that has run out and for `prev` at the first track too,
/// where resuming mid-track would be wrong. Those cases are indistinguishable in the event,
/// which carries only a play-request id and a track id.
///
/// So the resume point is captured where the cause *is* known: the `SessionDisconnected`
/// arm, which librespot emits from `handle_disconnect` before the `handle_stop` that
/// follows it.
///
/// One rule governs its lifetime: it survives until something newer describes where
/// playback is. That is a `Loading` event, which establishes the position for the track it
/// names, or a `Playing` event; a full cleanup drops it with the rest of the session.
///
/// The resume path only reads it, never takes it. `Spirc::load` merely queues a command, so
/// a resume that has been *attempted* is not one that has *landed*: clearing on the attempt
/// would leave a retry after a failed or silent load with nothing but the zero that
/// `Stopped` wrote. Clearing on `Loading` instead is safe precisely because that event
/// carries the seek target the resume passed in, so the live position already holds it.
pub(crate) static RESUME_POSITION_MS: AtomicU32 = AtomicU32::new(0);

// Current track duration (ms) - updated from TrackChanged event
pub(crate) static CURRENT_DURATION_MS: AtomicU32 = AtomicU32::new(0);

// Current logical track URI - for UI identity and detecting same-track reconnects.
// The playable AudioItem may carry a different URI after Spotify relinking.
//
// Session-scoped: `spotty_playback_cleanup` drops it, because resume-load (Swift reads it
// through `spotty_playback_get_resume_track_uri` for user resume and reconnect rehydration
// alike) would otherwise hand it to a load made by whichever account logged in next.
pub(crate) static CURRENT_TRACK_URI: Lazy<Mutex<Option<String>>> = Lazy::new(|| Mutex::new(None));

/// Stores the requested/context track identity exposed by librespot player events.
///
/// Keep callback delivery outside this helper: Swift callbacks may re-enter Rust and
/// must never run while `CURRENT_TRACK_URI` is locked.
pub(crate) fn set_current_track_uri(track_uri: String) {
    let mut uri_guard = CURRENT_TRACK_URI.lock().unwrap_or_else(|e| e.into_inner());
    *uri_guard = Some(track_uri);
}

// Current context URI - captured from SetQueue and cluster player state updates.
// We keep the latest non-empty value to recover resume after reconnect.
//
// Session-scoped for the same reason as CURRENT_TRACK_URI above, and more sharply: this is
// what a resume actually loads. "Latest non-empty" means a login cannot clear it by arriving,
// so the cleanup has to.
pub(crate) static CURRENT_CONTEXT_URI: Lazy<Mutex<Option<String>>> = Lazy::new(|| Mutex::new(None));

// Connection state tracking - for transparency dashboard. See ConnectionState above;
// reconnect attempt, connected-since, and last error all live there now.
// Wake timing tracking - for debugging reconnection timing issues
pub(crate) static WAKE_TIMESTAMP_MS: AtomicU64 = AtomicU64::new(0);

/// Returns milliseconds elapsed since wake was triggered (force_reconnect called).
/// Returns 0 if no wake timestamp recorded.
pub(crate) fn elapsed_since_wake_ms() -> u64 {
    let wake_ts = WAKE_TIMESTAMP_MS.load(Ordering::SeqCst);
    if wake_ts == 0 {
        return 0;
    }
    let now = current_timestamp_ms();
    now.saturating_sub(wake_ts)
}

// Generation counter for reconnection. Bumped once per rebuild, in build_player_async, and
// captured by every listener that rebuild creates. A listener whose captured generation no
// longer matches belongs to a session that has already been replaced, and must not act.
//
// There used to be a second global, EVENT_LISTENER_GENERATION, holding "the generation the
// current event listener belongs to". Soft reconnect kept one listener alive across
// sessions, so the listener could not simply capture its generation — and the global was
// written to the new value on every bump, which made the two always equal and the staleness
// check unreachable. Now that a rebuild replaces the listener along with its session, the
// listener captures the value directly and the check does what it claims.
pub(crate) static SESSION_GENERATION: AtomicU64 = AtomicU64::new(0);

/// Serializes short, synchronous mutations against the generation invalidation point.
///
/// The async lifecycle mutex cannot be used by player callbacks or synchronous FFI commands:
/// lifecycle initialization deliberately holds it while waiting for rehydration. This gate is
/// therefore intentionally small and synchronous. Callers must finish all state reads/writes or
/// command-channel sends inside the closure, then invoke callbacks after it returns. No foreign
/// callback may run while this mutex is held.
static GENERATION_MUTATION_GATE: Lazy<Mutex<()>> = Lazy::new(|| Mutex::new(()));

/// Runs one generation-owned synchronous operation while invalidation is excluded.
pub(crate) fn with_generation_mutation<T>(work: impl FnOnce() -> T) -> T {
    let _gate = GENERATION_MUTATION_GATE
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    work()
}

/// Runs `work` only while `generation` still owns the engine mutation point.
///
/// The generation check and the closure are protected by the same gate used by
/// [`invalidate_cluster_generation`]. This closes the check-then-act window for event state
/// writes and rehydration command sends without holding an async lifecycle lock.
pub(crate) fn with_current_generation_mutation<T>(
    generation: u64,
    work: impl FnOnce() -> T,
) -> Option<T> {
    with_generation_mutation(|| {
        listener_may_act(generation, SESSION_GENERATION.load(Ordering::SeqCst)).then(work)
    })
}
/// Bumped only when the account itself goes away — logout, or app termination. Distinct from
/// `SESSION_GENERATION`, which moves on every ordinary rebuild: cleanup and
/// `build_player_async` both advance it, so a long-running streaming grant waiting on a
/// browser would see any concurrent play, retry or wake as a supersession and delete the
/// credentials it had just written.
pub(crate) static LOGOUT_GENERATION: AtomicU64 = AtomicU64::new(0);

/// Generation created by the most recent `build_player_async`. Lets the reconnect loop adopt
/// the generation its own attempt made rather than whatever the counter reads afterwards,
/// which may belong to a logout and the login that followed it.
pub(crate) static LAST_BUILD_GENERATION: AtomicU64 = AtomicU64::new(0);

// Swift resolves the user-facing macOS Computer Name and supplies the full Connect label.
pub(crate) static CONNECT_DEVICE_NAME_SETTING: Lazy<Mutex<Option<String>>> =
    Lazy::new(|| Mutex::new(None));

/// Current-track identity on a queue snapshot. Presentation labels are Swift-owned.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct QueueItem {
    pub(crate) uri: String,
    /// Track provider: "context", "queue", "autoplay", or "unavailable"
    pub(crate) provider: String,
    /// Connect occurrence uid when the cluster supplied one. Empty when unknown.
    pub(crate) uid: String,
}

/// Unfiltered Connect queue row used for `set_queue` replacement.
/// Fields match `ProvidedTrack` in player.proto at librespot a1b66d3, except
/// `disallow_setting_modes` / `disallow_signals` maps which are omitted when empty
/// (no evidence they appear on queue rows in official `set_queue` JSON).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ProtocolQueueTrack {
    pub(crate) uri: String,
    pub(crate) uid: String,
    pub(crate) provider: String,
    pub(crate) metadata: HashMap<String, String>,
    pub(crate) removed: Vec<String>,
    pub(crate) blocked: Vec<String>,
    pub(crate) restrictions: HashMap<String, Vec<String>>,
    pub(crate) album_uri: String,
    pub(crate) disallow_reasons: Vec<String>,
    pub(crate) artist_uri: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct QueueState {
    pub(crate) revision: u64,
    pub(crate) session_generation: u64,
    pub(crate) track: Option<QueueItem>,
    pub(crate) protocol_next_tracks: Vec<ProtocolQueueTrack>,
    pub(crate) protocol_prev_tracks: Vec<ProtocolQueueTrack>,
    pub(crate) queue_revision: String,
    pub(crate) disallow_set_queue: bool,
    pub(crate) disallow_removing_from_next_tracks: bool,
}

/// One cluster member as observed on the wire. Activity and unused Web API fields
/// are Swift-owned (`ConnectDeviceProjection`).
#[derive(Clone, PartialEq, Eq)]
pub(crate) struct ProtocolConnectDevice {
    pub(crate) id: String,
    pub(crate) name: String,
    pub(crate) device_type: String,
}

/// Get current timestamp in milliseconds since UNIX epoch
pub(crate) fn current_timestamp_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::ZERO)
        .as_millis() as u64
}

/// Update position from player event
pub(crate) fn update_position(position_ms: u32) {
    POSITION_MS.store(position_ms, Ordering::SeqCst);
}

pub(crate) fn update_current_context_uri(context_uri: &str) {
    if context_uri.is_empty() {
        return;
    }
    let mut context_guard = CURRENT_CONTEXT_URI
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    *context_guard = Some(context_uri.to_string());
}

pub(crate) fn update_playback_options(shuffle: bool, repeat_track: bool, repeat_context: bool) {
    SHUFFLE_STATE.store(shuffle, Ordering::SeqCst);
    REPEAT_TRACK_STATE.store(repeat_track, Ordering::SeqCst);
    REPEAT_CONTEXT_STATE.store(repeat_context, Ordering::SeqCst);
}

pub(crate) fn current_playback_options() -> (bool, bool, bool) {
    (
        SHUFFLE_STATE.load(Ordering::SeqCst),
        REPEAT_TRACK_STATE.load(Ordering::SeqCst),
        REPEAT_CONTEXT_STATE.load(Ordering::SeqCst),
    )
}
