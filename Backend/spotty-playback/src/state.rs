use crate::*;
use std::collections::HashMap;
use std::sync::OnceLock;
use std::time::Instant;

/// One `PlayerEvent::Playing` publication.
///
/// The sequence gives ordinary play/load waits an edge to wait past. Reconnect rehydration
/// additionally needs the listener generation that produced that exact edge. Keep both facts
/// behind one lock: separate atomics can be read as a record that was never published (for
/// example, an old sequence paired with a newly written generation).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct PlayingEventStamp {
    pub(crate) generation: u64,
    pub(crate) sequence: u64,
}

/// Fingerprint of the last `(active_device_id, protocol members)` sent to Swift, so an
/// unchanged cluster update stays silent. Cluster updates arrive for every playback tick,
/// and the device list changes far more rarely. Activity changes still fire because the
/// active id is part of the fingerprint.
#[derive(Clone, PartialEq, Eq)]
pub(crate) struct DevicesFingerprint {
    pub(crate) active_device_id: String,
    pub(crate) devices: Vec<ProtocolConnectDevice>,
}

/// Everything the engine's connection observation is assembled from.
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
///
/// The struct itself is now a field of [`EngineGeneration`], which extends that same
/// argument to the rest of the generation's state.
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

/// Everything scoped to one engine generation, behind one lock.
///
/// The six connection fields were merged first, because a snapshot assembled from
/// independent globals could mix values from different transitions. The same argument
/// covers the whole generation: `PLAYER`, `SESSION`, `MIXER`, `SPIRC`, `PLAYER_EVENT_TX`,
/// `ENGINE_TASKS`, `IS_PLAYING`, `PLAYING_EVENT_STAMP`, `RESUMING`, the shuffle/repeat
/// option atomics, `LAST_QUEUE` and `LAST_DEVICES_FINGERPRINT` were all independent process
/// statics, so a stale generation could write one of them after a newer generation had
/// already published its own, and a reader assembling several of them could observe a state
/// that never existed.
///
/// `session_generation` tags the state with the generation that owns it. It is kept equal to
/// the [`SESSION_GENERATION`] counter by [`advance_session_generation`], which bumps both
/// under the same gate. [`with_engine_owned`] therefore turns "is my generation still
/// current?" from a check-then-act against a separate atomic into one atomic decision taken
/// with the write it guards: a caller naming a superseded generation is refused with
/// [`StaleGeneration`] instead of clobbering its replacement.
///
/// Hot paths: none of this is touched by the audio thread. `proxy_sink` owns PCM delivery and
/// its own callback slots and shares no state with this struct, so consolidating these globals
/// adds no lock acquisition to the real-time path and no atomic mirror is required. The
/// playing flag is read only by FFI commands, player events, and recovery capture, all of
/// which already take locks.
///
/// Discipline (see `AGENTS.md`): the guard never escapes an accessor, is never held across an
/// `.await`, and no Swift callback is invoked while it is held. Every accessor below finishes
/// its reads and writes and returns a plain value.
#[derive(Default)]
pub(crate) struct EngineGeneration {
    /// The generation that owns this state; mirrors [`SESSION_GENERATION`].
    pub(crate) session_generation: u64,
    /// Player state. The retained engine has one production player implementation: librespot's
    /// own `Player`, which decodes in-process and delivers bounded PCM through `proxy_sink`.
    pub(crate) player: Option<Arc<Player>>,
    pub(crate) session: Option<Session>,
    pub(crate) mixer: Option<Arc<SoftMixer>>,
    pub(crate) spirc: Option<Arc<Spirc>>,
    pub(crate) player_event_tx: Option<mpsc::UnboundedSender<()>>,
    /// Join handles for every task created for the current engine generation.
    ///
    /// Keeping the handles together makes teardown an owned operation: a failed build can
    /// cancel all work it started, and a normal generation replacement can await the old tasks
    /// before dropping the objects they retain. The vector is taken before cancellation, so no
    /// task is ever awaited while holding this lock.
    pub(crate) tasks: Option<Vec<JoinHandle<()>>>,
    /// Local playing flag. `true` only after `PlayerEvent::Playing`. `Spirc::load` `Ok` means
    /// the command was queued, not that audio started, so the play commands must not set it:
    /// `resume_playback` returns success without issuing play or its fallback whenever this
    /// flag is already set.
    ///
    /// Private on purpose. The only way it becomes `true` is [`EngineGeneration::note_playing_event`],
    /// which is inseparable from publishing a Playing event — the compiler now enforces what the
    /// retired `rust-playing-store-owner` / `rust-playing-store-required` ast-grep rules used to
    /// assert about the literal `IS_PLAYING.store(true, ...)` spelling.
    is_playing: bool,
    playing_event: PlayingEventStamp,
    /// Set while a `spotty_playback_resume` is working, so only one runs at a time.
    ///
    /// Resuming is not instantaneous: `Spirc::play` only queues a command, then that export
    /// waits briefly for a `Playing` event. Swift `RustPlaybackEngine` then iterates
    /// `ResumeLoadPlan` targets through `spotty_playback_load` (reconnect rehydration issues the
    /// same targets inside `build_player_async`'s window). `PlaybackCoordinator` serializes that
    /// whole `execute(.resume)` so the app path does not stack play-then-load. This flag still
    /// covers overlapping C `spotty_playback_resume` calls. The playing flag does not cover the
    /// gap: it stays false until the first sequence actually produces audio.
    resuming: bool,
    pub(crate) shuffle: bool,
    pub(crate) repeat_track: bool,
    pub(crate) repeat_context: bool,
    /// The last queue the cluster described, so Swift can ask again rather than re-deriving it
    /// from the Web API. See `spotty_playback_get_queue_snapshot`.
    pub(crate) last_queue: Option<QueueState>,
    pub(crate) last_devices_fingerprint: Option<DevicesFingerprint>,
    pub(crate) connection: ConnectionState,
}

impl EngineGeneration {
    pub(crate) fn is_playing(&self) -> bool {
        self.is_playing
    }

    /// Records that playback has stopped. Any owner may clear the flag; only a Playing event
    /// can set it.
    pub(crate) fn clear_playing(&mut self) {
        self.is_playing = false;
    }

    /// Publishes a Playing event as one coherent `(generation, sequence)` record, and marks
    /// playback running.
    ///
    /// This is the single transition that can make the engine report playing. Nothing else can:
    /// the flag is private to this module, so a play/load command cannot claim success the
    /// player never reported.
    pub(crate) fn note_playing_event(&mut self, generation: u64) -> PlayingEventStamp {
        self.is_playing = true;
        self.playing_event.generation = generation;
        self.playing_event.sequence = self.playing_event.sequence.wrapping_add(1);
        self.playing_event
    }

    /// Reads the last Playing event's generation and sequence as one record.
    pub(crate) fn playing_event(&self) -> PlayingEventStamp {
        self.playing_event
    }

    /// Claims the resume slot, returning false when another resume already owns it.
    pub(crate) fn claim_resume(&mut self) -> bool {
        if self.resuming {
            return false;
        }
        self.resuming = true;
        true
    }

    pub(crate) fn release_resume(&mut self) {
        self.resuming = false;
    }

    /// Whether the stored Session exists and has been invalidated.
    pub(crate) fn session_is_invalid(&self) -> bool {
        self.session.as_ref().is_some_and(|s| s.is_invalid())
    }

    /// Whether there is no usable Session: none stored, or a stored one that is invalid.
    pub(crate) fn session_missing_or_invalid(&self) -> bool {
        self.session.as_ref().is_none_or(|s| s.is_invalid())
    }

    #[cfg(test)]
    pub(crate) fn replace_playing_event_for_test(&mut self, stamp: PlayingEventStamp) {
        self.playing_event = stamp;
    }

    #[cfg(test)]
    fn set_playing_for_test(&mut self, is_playing: bool) {
        self.is_playing = is_playing;
    }
}

/// The one lock holding generation-scoped engine state.
pub(crate) static ENGINE: Lazy<Mutex<EngineGeneration>> =
    Lazy::new(|| Mutex::new(EngineGeneration::default()));

/// A write named a generation that no longer owns the engine. The caller logs or ignores it;
/// it is never an error the boundary reports.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct StaleGeneration;

/// Runs `f` against the engine generation under its single lock.
///
/// The guard never leaves this function: callers finish their reads and writes inside the
/// closure and act on the returned value afterwards. Never invoke a Swift callback, take the
/// lifecycle mutex, or `await` from inside `f` — this is a synchronous `std` mutex.
pub(crate) fn with_engine<R>(f: impl FnOnce(&mut EngineGeneration) -> R) -> R {
    let mut engine = ENGINE.lock().unwrap_or_else(|e| e.into_inner());
    f(&mut engine)
}

/// Runs `f` only while `generation` still owns the engine.
///
/// The generation comparison and the write happen under the same lock, so a stale listener,
/// reconnect, or cancelled build cannot pass the check and then write state a newer generation
/// already published.
pub(crate) fn with_engine_owned<R>(
    generation: u64,
    f: impl FnOnce(&mut EngineGeneration) -> R,
) -> Result<R, StaleGeneration> {
    with_engine(|engine| {
        if engine.session_generation != generation {
            return Err(StaleGeneration);
        }
        Ok(f(engine))
    })
}

/// Mutates the connection state under the engine lock and returns whatever `f` returns.
///
/// Does not publish — callers decide when to `notify_connection_state_change()`, so a
/// multi-field transition emits one snapshot rather than one per field. Never call
/// `notify_connection_state_change()` from inside `f`: it takes the engine lock too.
pub(crate) fn with_connection<R>(f: impl FnOnce(&mut ConnectionState) -> R) -> R {
    with_engine(|engine| f(&mut engine.connection))
}

/// Mutates the connection state only while `generation` still owns the engine.
pub(crate) fn with_connection_owned<R>(
    generation: u64,
    f: impl FnOnce(&mut ConnectionState) -> R,
) -> Result<R, StaleGeneration> {
    with_engine_owned(generation, |engine| f(&mut engine.connection))
}

/// A complete generation, constructed locally and not yet visible to commands or teardown.
pub(crate) struct StagedEngine {
    pub(crate) session: Session,
    pub(crate) player: Arc<Player>,
    pub(crate) mixer: Arc<SoftMixer>,
    pub(crate) spirc: Arc<Spirc>,
    pub(crate) tasks: Vec<JoinHandle<()>>,
    pub(crate) device_id: String,
    pub(crate) active_device: bool,
}

/// Installs a fully constructed generation in one lock acquisition.
///
/// Refuses when `generation` no longer owns the engine, and hands the staged values back so the
/// caller can roll them back. Dropping them here instead would detach their Tokio tasks into the
/// generation that superseded this one.
pub(crate) fn publish_engine_generation(
    generation: u64,
    staged: StagedEngine,
) -> Result<(), StagedEngine> {
    let mut pending = Some(staged);
    with_engine(|engine| {
        if engine.session_generation != generation {
            return Err(pending.take().expect("staged generation is present once"));
        }
        let staged = pending.take().expect("staged generation is present once");
        engine.session = Some(staged.session);
        engine.player = Some(staged.player);
        engine.mixer = Some(staged.mixer);
        engine.spirc = Some(staged.spirc);
        // The pump is started after publication; its sender is installed by
        // `set_player_event_tx` once it exists.
        engine.player_event_tx = None;
        engine.tasks = Some(staged.tasks);
        engine.connection.device_id = Some(staged.device_id);
        engine.connection.spirc_ready = false;
        engine.connection.session_connected = false;
        engine.connection.resume_pending = false;
        engine.connection.credentials_rejected = false;
        engine.connection.last_error = None;
        engine.connection.is_active_device = staged.active_device;
        Ok(())
    })
}

/// Installs the player-event pump's stop sender for the generation that owns it.
pub(crate) fn set_player_event_tx(
    generation: u64,
    sender: mpsc::UnboundedSender<()>,
) -> Result<(), StaleGeneration> {
    with_engine_owned(generation, |engine| engine.player_event_tx = Some(sender))
}

/// Appends a generation-owned task handle to its registry.
///
/// A refused handle is aborted rather than dropped: dropping a `JoinHandle` detaches the task,
/// which would leave a superseded generation's work running against a live successor. The abort
/// happens after the lock is released.
pub(crate) fn push_engine_task(
    generation: u64,
    task: JoinHandle<()>,
) -> Result<(), StaleGeneration> {
    let mut refused = Some(task);
    let result = with_engine(|engine| {
        if engine.session_generation != generation {
            return Err(StaleGeneration);
        }
        let Some(tasks) = engine.tasks.as_mut() else {
            return Err(StaleGeneration);
        };
        tasks.push(refused.take().expect("task handle is present once"));
        Ok(())
    });
    if let Some(task) = refused {
        task.abort();
    }
    result
}

/// Returns the current concrete librespot Player without holding the engine lock.
pub(crate) fn current_player() -> Option<Arc<Player>> {
    with_engine(|engine| engine.player.clone())
}

/// Returns the current Spirc without holding the engine lock.
pub(crate) fn current_spirc_handle() -> Option<Arc<Spirc>> {
    with_engine(|engine| engine.spirc.clone())
}

/// Returns a clone of the current Session, so callers never hold the engine lock across an
/// upstream call.
pub(crate) fn current_session() -> Option<Session> {
    with_engine(|engine| engine.session.clone())
}

/// Whether the engine currently reports local playback.
pub(crate) fn engine_is_playing() -> bool {
    with_engine(|engine| engine.is_playing())
}

/// Records that local playback has stopped.
pub(crate) fn clear_engine_playing() {
    with_engine(|engine| engine.clear_playing());
}

/// Publishes a Playing event as one coherent `(generation, sequence)` record.
pub(crate) fn publish_playing_event(generation: u64) -> PlayingEventStamp {
    with_engine(|engine| engine.note_playing_event(generation))
}

/// Reads the last Playing event's generation and sequence as one record.
pub(crate) fn playing_event_stamp() -> PlayingEventStamp {
    with_engine(|engine| engine.playing_event())
}

#[cfg(test)]
pub(crate) fn replace_playing_event_stamp_for_test(stamp: PlayingEventStamp) {
    with_engine(|engine| engine.replace_playing_event_for_test(stamp));
}

/// Test-only override of the playing flag, used to arrange and restore a starting state.
///
/// Production code has no equivalent: [`EngineGeneration::note_playing_event`] is the only way
/// the flag becomes true, which is what makes "only a Playing event reports playing" a
/// compile-time property rather than a syntactic policy check.
#[cfg(test)]
pub(crate) fn set_engine_playing_for_test(is_playing: bool) {
    with_engine(|engine| engine.set_playing_for_test(is_playing));
}

/// Clears the resume claim however `spotty_playback_resume` returns.
pub(crate) struct ResumeGuard;

impl Drop for ResumeGuard {
    fn drop(&mut self) {
        with_engine(|engine| engine.release_resume());
    }
}

/// Process-lifetime control callback registry.
///
/// Each slot keeps an independent lock, so a callback on one event stream cannot block another.
/// Call sites always copy the function pointer and release its slot before entering Swift. PCM
/// and audio-control callbacks remain in `proxy_sink`: the real-time audio path does not touch
/// this registry or any of these locks.
///
/// Process-lifetime on purpose: Swift registers these once at startup and a generation
/// replacement must not silence them.
#[derive(Default)]
pub(crate) struct ControlCallbacks {
    pub(crate) queue: Mutex<Option<QueueSnapshotCallback>>,
    pub(crate) playback_state: Mutex<Option<PlaybackSnapshotCallback>>,
    pub(crate) devices: Mutex<Option<DevicesSnapshotCallback>>,
    pub(crate) connection_state: Mutex<Option<ConnectionSnapshotCallback>>,
    pub(crate) connect_cluster_state: Mutex<Option<ConnectClusterStateCallback>>,
}

pub(crate) static CONTROL_CALLBACKS: Lazy<ControlCallbacks> = Lazy::new(ControlCallbacks::default);

/// Stores a devices fingerprint if it differs from the last one, returning whether it changed.
///
/// Compare-and-set under the one lock, so two cluster ticks cannot both decide they are the
/// change and publish the same list twice.
pub(crate) fn record_devices_fingerprint(fingerprint: DevicesFingerprint) -> bool {
    with_engine(|engine| {
        if engine.last_devices_fingerprint.as_ref() == Some(&fingerprint) {
            return false;
        }
        engine.last_devices_fingerprint = Some(fingerprint);
        true
    })
}

/// Replaces the cached cluster queue snapshot.
pub(crate) fn store_last_queue(queue: Option<QueueState>) {
    with_engine(|engine| engine.last_queue = queue);
}

/// Returns the cached cluster queue snapshot.
pub(crate) fn last_queue_snapshot() -> Option<QueueState> {
    with_engine(|engine| engine.last_queue.clone())
}

/// Drops both cluster-derived caches together on a full cleanup.
///
/// They describe one account: clearing them separately left a window in which the queue was
/// already gone while the device dedup cache still suppressed the next login's first update.
pub(crate) fn clear_cluster_caches() {
    with_engine(|engine| {
        engine.last_queue = None;
        engine.last_devices_fingerprint = None;
    });
}

/// Serializes snapshot building so a revision always orders snapshots by the state they
/// actually saw. Held only across the build, never across delivery into Swift.
///
/// Process-lifetime: revisions are process-monotonic across generations, which is what lets
/// Swift reject a late callback from a session that has already been replaced.
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

// Process flags, deliberately not part of EngineGeneration. Both describe an intent that
// outlives every generation: they are set before a teardown and are read by recovery,
// construction and the health check precisely when there may be no generation at all — and
// `spotty_playback_init_player` clears them before any generation exists to write them into.
// Folding them into the generation struct would tie "the user asked us to stop" to whichever
// engine instance happened to be installed.
//
// Flag to track intentional shutdown (prevents reconnection attempts during app quit)
pub(crate) static SHUTTING_DOWN: AtomicBool = AtomicBool::new(false);
// Flag to track sleep state (prevents auto-reconnect, but allows explicit forceReconnect on wake)
pub(crate) static SLEEPING: AtomicBool = AtomicBool::new(false);

/// Records a definitive credential rejection. The generation owner captures and delivers the notification.
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
/// the deactivation handler clears the active flag, a `Stopped` event clears the playing flag,
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
    ///
    /// Both facts come out of one lock acquisition, so the intent can never pair "was playing"
    /// from before a transition with "was active" from after it.
    pub(crate) fn capture() -> Self {
        with_engine(|engine| Self {
            was_playing: engine.is_playing(),
            was_active: engine.connection.is_active_device,
        })
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

/// Returns the device ID assigned at session creation, if a session has been built.
pub(crate) fn current_device_id() -> Option<String> {
    with_connection(|c| c.device_id.clone())
}

// Position tracking - updated from player events
pub(crate) static POSITION_MS: AtomicU32 = AtomicU32::new(0);

/// The last position report as one word for `player_control::displayed_position_ms`: the
/// position in the high 32 bits and the low 32 bits of the monotonic millisecond it arrived.
/// Written atomically so a reader never pairs a new position with an older arrival time.
/// Zero arrival bits mean no report since the last reset.
pub(crate) static POSITION_REPORT: AtomicU64 = AtomicU64::new(0);

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
// Process-lifetime: the counter has to survive the generation it invalidates, and it is read
// by tasks that no longer own any engine state. `EngineGeneration::session_generation` mirrors
// it so an ownership check and the write it guards can share one lock.
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
///
/// Lock order is always this gate, then the engine lock. No engine accessor takes it back.
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
/// [`advance_session_generation`]. This closes the check-then-act window for event state
/// writes and rehydration command sends without holding an async lifecycle lock.
pub(crate) fn with_current_generation_mutation<T>(
    generation: u64,
    work: impl FnOnce() -> T,
) -> Option<T> {
    with_generation_mutation(|| {
        listener_may_act(generation, SESSION_GENERATION.load(Ordering::SeqCst)).then(work)
    })
}

/// Advances the session generation counter and retags the engine state with it.
///
/// Both moves happen under the mutation gate, so the counter and
/// `EngineGeneration::session_generation` are never observed disagreeing. Everything a stale
/// owner might still try to write is refused by [`with_engine_owned`] from this point on.
pub(crate) fn advance_session_generation() -> u64 {
    with_generation_mutation(|| {
        with_engine(|engine| {
            let invalidated = SESSION_GENERATION.fetch_add(1, Ordering::SeqCst) + 1;
            engine.session_generation = invalidated;
            invalidated
        })
    })
}

/// Sets both the counter and the engine tag, returning the previous counter value.
///
/// Tests drive event application for a chosen generation; writing only the atomic would leave
/// the engine tagged with a different generation and every owned write refused.
#[cfg(test)]
pub(crate) fn set_session_generation_for_test(generation: u64) -> u64 {
    with_generation_mutation(|| {
        with_engine(|engine| {
            let previous = SESSION_GENERATION.swap(generation, Ordering::SeqCst);
            engine.session_generation = generation;
            previous
        })
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
// Process-lifetime: it is written before any generation exists and read by every later build.
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

/// Milliseconds since the first call in this process, starting at 1 so the value is never the
/// zero that `POSITION_REPORT` uses for "no report". Monotonic, so wall-clock adjustments
/// cannot move a reported position backwards or forwards.
pub(crate) fn monotonic_ms() -> u64 {
    static START: OnceLock<Instant> = OnceLock::new();
    START.get_or_init(Instant::now).elapsed().as_millis() as u64 + 1
}

pub(crate) fn pack_position_report(position_ms: u32, reported_at_ms: u64) -> u64 {
    (u64::from(position_ms) << 32) | u64::from(reported_at_ms as u32)
}

/// Returns `(position_ms, reported_at_ms)` with the arrival time truncated to 32 bits.
pub(crate) fn unpack_position_report(report: u64) -> (u32, u32) {
    ((report >> 32) as u32, report as u32)
}

/// Update position from player event
pub(crate) fn update_position(position_ms: u32) {
    POSITION_MS.store(position_ms, Ordering::SeqCst);
    let report = pack_position_report(position_ms, monotonic_ms());
    POSITION_REPORT.store(report, Ordering::SeqCst);
}

/// Clears the live position and its report so a new session cannot display a stale one.
pub(crate) fn reset_position() {
    POSITION_MS.store(0, Ordering::SeqCst);
    POSITION_REPORT.store(0, Ordering::SeqCst);
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

/// Stores the three playback options together, so a reader cannot see a mixture of an old
/// shuffle value and a new repeat value.
pub(crate) fn update_playback_options(shuffle: bool, repeat_track: bool, repeat_context: bool) {
    with_engine(|engine| {
        engine.shuffle = shuffle;
        engine.repeat_track = repeat_track;
        engine.repeat_context = repeat_context;
    });
}

/// Records a shuffle change reported by the player, leaving repeat alone.
pub(crate) fn update_shuffle_option(shuffle: bool) {
    with_engine(|engine| engine.shuffle = shuffle);
}

/// Records a repeat change reported by the player, leaving shuffle alone.
pub(crate) fn update_repeat_options(repeat_track: bool, repeat_context: bool) {
    with_engine(|engine| {
        engine.repeat_track = repeat_track;
        engine.repeat_context = repeat_context;
    });
}

pub(crate) fn current_playback_options() -> (bool, bool, bool) {
    with_engine(|engine| (engine.shuffle, engine.repeat_track, engine.repeat_context))
}
