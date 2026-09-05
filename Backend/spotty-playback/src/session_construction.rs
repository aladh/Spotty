use super::*;
/// Builds librespot's own Player, decoding in-process and delivering PCM through `proxy_sink.rs`.
fn create_librespot_player(session: &Session) -> Arc<Player> {
    let player_config = PlayerConfig {
        bitrate: Bitrate::Bitrate320,
        gapless: true,
        position_update_interval: Some(Duration::from_millis(200)),
        ..PlayerConfig::default()
    };
    let audio_format = AudioFormat::default();

    // Use ProxySink - a persistent audio output that survives across Player instances.
    // This enables seamless audio during session reconnection.
    //
    // NoOpVolume: do NOT attenuate samples here. Volume is applied at the output
    // (AVSampleBufferAudioRenderer.volume in Swift) so changes take effect
    // immediately instead of after the ~2s of already-decoded PCM drains. The
    // SoftMixer still tracks the logical volume for Spotify Connect reporting; it
    // just no longer feeds the player's sample gain.
    Player::new(
        player_config,
        session.clone(),
        Box::new(NoOpVolume),
        move || mk_proxy_sink(None, audio_format),
    )
}

/// Keeps a Session invalidated if an initialization future is cancelled at an await point.
///
/// `Session`'s `Drop` implementation only releases its Arc; it does not close the AP, dealer, or
/// channel managers. The guard is therefore kept alive until the transaction commits, and its
/// clone is harmless while the published Session is still in use.
pub(crate) struct SessionShutdownGuard {
    session: Option<Session>,
}

impl SessionShutdownGuard {
    pub(crate) fn new(session: Session) -> Self {
        Self {
            session: Some(session),
        }
    }

    pub(crate) fn disarm(&mut self) {
        self.session = None;
    }
}

impl Drop for SessionShutdownGuard {
    fn drop(&mut self) {
        if let Some(session) = self.session.as_ref() {
            session.shutdown();
        }
    }
}

/// Owns local resources until the generation reaches the atomic publication point.
///
/// Tokio detaches a task when its `JoinHandle` is simply dropped. This guard aborts every staged
/// handle and shuts down both Spirc and Session during cancellation, so a cancelled build cannot
/// leave work running after its future is gone. The explicit async rollback path below additionally
/// awaits those handles before proceeding to another build.
struct StagedGenerationGuard {
    spirc: Option<Arc<Spirc>>,
    session: Option<Session>,
    tasks: Vec<JoinHandle<()>>,
    armed: bool,
}

impl StagedGenerationGuard {
    fn new(spirc: Arc<Spirc>, session: Session, first_task: JoinHandle<()>) -> Self {
        Self {
            spirc: Some(spirc),
            session: Some(session),
            tasks: vec![first_task],
            armed: true,
        }
    }

    fn take_for_publish(mut self) -> (Arc<Spirc>, Session, Vec<JoinHandle<()>>) {
        self.armed = false;
        (
            self.spirc.take().expect("staged Spirc exists at commit"),
            self.session
                .take()
                .expect("staged Session exists at commit"),
            std::mem::take(&mut self.tasks),
        )
    }

    async fn rollback(mut self) {
        self.armed = false;
        let spirc = self
            .spirc
            .take()
            .expect("staged Spirc exists before rollback");
        let session = self
            .session
            .take()
            .expect("staged Session exists before rollback");
        rollback_staged_generation(spirc, session, std::mem::take(&mut self.tasks)).await;
    }
}

impl Drop for StagedGenerationGuard {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        let spirc = self.spirc.take();
        let tasks = std::mem::take(&mut self.tasks);
        shutdown_spirc_and_tasks_sync(
            spirc.as_ref(),
            self.session.as_ref(),
            tasks,
            "staged construction cancellation",
        );
        if let Some(session) = self.session.as_ref() {
            session.shutdown();
        }
    }
}

/// Aborts a generation that has been constructed but not published.
///
/// Every handle is aborted and joined after Spirc shutdown has been queued.
/// This helper is only called by the lifecycle owner; generation children request recovery and do
/// not call it themselves, so no task can await or abort its own handle.
async fn rollback_staged_generation(
    spirc: Arc<Spirc>,
    session: Session,
    tasks: Vec<JoinHandle<()>>,
) {
    shutdown_spirc_and_tasks(
        Some(&spirc),
        Some(&session),
        tasks,
        "staged construction rollback",
    )
    .await;
}

/// Rolls back an installed generation only if it still owns the global slots.
///
/// Cleanup can invalidate the generation while this build is waiting for a rehydration event. In
/// that case the cleanup owner will take the slots after the lifecycle lock is released; touching
/// them here would destroy the newer owner. The final generation check therefore guards both
/// teardown and the state reset.
async fn rollback_installed_generation(generation: u64) {
    if !listener_may_act(generation, SESSION_GENERATION.load(Ordering::SeqCst)) {
        return;
    }

    let _store = enter_store_section();
    teardown_engine_resources("initialization rollback").await;
    with_connection(|c| {
        c.spirc_ready = false;
        c.session_connected = false;
        c.resume_pending = false;
        c.device_id = None;
        c.is_active_device = false;
    });
    notify_connection_state_change();
}

/// Synchronous cancellation fallback for the short interval after publication and before the
/// initialization future returns. It only touches globals when this generation still owns them;
/// a newer owner or a waiting cleanup is left alone. Normal teardown uses the async owner so it
/// can await every handle.
struct InstalledGenerationGuard {
    generation: u64,
    armed: bool,
}

impl InstalledGenerationGuard {
    fn new(generation: u64) -> Self {
        Self {
            generation,
            armed: true,
        }
    }

    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for InstalledGenerationGuard {
    fn drop(&mut self) {
        if !self.armed
            || !listener_may_act(self.generation, SESSION_GENERATION.load(Ordering::SeqCst))
        {
            return;
        }

        let _store = enter_store_section();
        let resources = take_engine_resources();
        if let Some(tx) = resources.stop_tx {
            let _ = tx.send(());
        }
        shutdown_spirc_and_tasks_sync(
            resources.spirc.as_ref(),
            resources.session.as_ref(),
            resources.tasks,
            "installed generation cancellation",
        );
        if let Some(session) = resources.session.as_ref() {
            session.shutdown();
        }
        *PLAYER.lock().unwrap_or_else(|e| e.into_inner()) = None;
        *MIXER.lock().unwrap_or_else(|e| e.into_inner()) = None;
        with_connection(|c| {
            c.spirc_ready = false;
            c.session_connected = false;
            c.resume_pending = false;
            c.device_id = None;
            c.is_active_device = false;
        });
    }
}

/// Records a definitive initialization failure only while its generation still owns the session.
///
/// A stale reconnect can finish after a newer grant or session has taken over. It must not clear
/// that newer credential cache or publish a rejection against it, so both the generation and the
/// intentional-teardown state are checked immediately before the cache mutation.
fn publish_initialization_failure(generation: u64, failure: InitializationFailure) {
    if failure != InitializationFailure::CredentialsRejected
        || !listener_may_act(generation, SESSION_GENERATION.load(Ordering::SeqCst))
        || teardown_in_progress()
    {
        return;
    }

    clear_resolved_credentials();
    mark_credentials_rejected();
}

/// Builds a complete, settled session and publishes its readiness exactly once, at the end.
///
/// The ordering matters. Readiness used to be published the moment Spirc existed, while
/// activation and the rehydrating load still had to run — so Swift, which reacts to that
/// publication by bootstrapping from the Web API, fetched and applied a server snapshot
/// that Rust then immediately overwrote. That was visible as the playback position jumping
/// forward to a stale value and back. Publishing readiness once, when nothing further is
/// pending, removes the window rather than racing it.
///
/// The rehydrating load itself is Swift's. When local playback is being recovered, this
/// function publishes one snapshot with `session_connected` set, `spirc_ready` still clear,
/// and `resume_pending` set; Swift answers by issuing its `ResumeLoadPlan` targets through
/// `spotty_playback_load`, and this function holds readiness until a Playing event lands,
/// a load reports a dead Spirc, or [`REHYDRATION_WINDOW`] elapses. Target order and
/// capture stay in one place (Swift); the engine keeps only the session globals the plan
/// reads through the existing getters.
pub(crate) async fn build_player_async(
    access_token: Option<&str>,
    activate_after_connect: bool,
    resume_after_connect: bool,
) -> Result<(), InitializationFailure> {
    let current_generation = tokio::task::spawn_blocking(invalidate_cluster_generation)
        .await
        .map_err(|_| InitializationFailure::Transient)?;
    LAST_BUILD_GENERATION.store(current_generation, Ordering::SeqCst);
    debug!(
        "[WAKE +{}ms] build_player_async starting, generation={}",
        elapsed_since_wake_ms(),
        current_generation
    );

    let device_id = format!("spotty_playback_{}", std::process::id());
    let (session, credentials) =
        create_session(&device_id, access_token).map_err(|_| InitializationFailure::Transient)?;
    let mut session_guard = SessionShutdownGuard::new(session.clone());

    // Create new mixer
    let mixer_config = MixerConfig::default();
    let mixer: Arc<SoftMixer> =
        Arc::new(SoftMixer::open(mixer_config).map_err(|_| InitializationFailure::Transient)?);

    // Create new player - must be created with the new session because Player is
    // tightly coupled to Session's ChannelManager for decryption key requests
    let player = create_librespot_player(&session);
    // Subscribe before Spirc can emit startup or activation events, but defer applying them
    // until the generation is installed. Dropping a failed local build drops this receiver too.
    let event_channel = player.get_player_event_channel();
    let (spirc, spirc_task) =
        match create_spirc(&session, &credentials, player.clone(), mixer.clone()).await {
            Ok(resources) => resources,
            Err(failure) => {
                publish_initialization_failure(current_generation, failure);
                return Err(failure);
            }
        };
    let staged = StagedGenerationGuard::new(spirc.clone(), session.clone(), spirc_task);

    // Run activation while the generation is still local. A failed command therefore cannot
    // leave a globally visible Session/Player/Spirc or a task registry that cleanup must guess
    // how to recover.
    let active_device = if activate_after_connect {
        match spirc.activate() {
            Ok(()) => true,
            Err(error) => {
                let failure = match classify_spirc_command_failure(&error) {
                    SpircCommandFailure::CredentialRejected => {
                        InitializationFailure::CredentialsRejected
                    }
                    SpircCommandFailure::NeedsReinit | SpircCommandFailure::Ordinary => {
                        InitializationFailure::Transient
                    }
                };
                debug!("Auto-activation failed ({:?})", failure);
                staged.rollback().await;
                session_guard.disarm();
                publish_initialization_failure(current_generation, failure);
                return Err(failure);
            }
        }
    } else {
        false
    };

    // The generation may have been invalidated while Spirc was connecting. Roll the local
    // resources back before publication so a stale transaction never becomes visible to commands
    // or a later teardown.
    if !listener_may_act(
        current_generation,
        SESSION_GENERATION.load(Ordering::SeqCst),
    ) || teardown_in_progress()
    {
        staged.rollback().await;
        session_guard.disarm();
        return Err(InitializationFailure::Transient);
    }

    // Every constructor has succeeded. Publish the complete generation in one store section;
    // no callback is emitted until all object slots and task ownership are present.
    let (staged_spirc, staged_session, staged_tasks) = staged.take_for_publish();
    // Ownership moved into the global slots below; the local clone must not shut down the
    // published Session if a later await is cancelled. `InstalledGenerationGuard` now owns the
    // cancellation rollback for the published generation.
    session_guard.disarm();
    let mut installed_guard = InstalledGenerationGuard::new(current_generation);
    {
        let _store = enter_store_section();
        let spirc = Arc::clone(&staged_spirc);
        *SESSION.lock().unwrap_or_else(|e| e.into_inner()) = Some(staged_session);
        *PLAYER.lock().unwrap_or_else(|e| e.into_inner()) = Some(player);
        *MIXER.lock().unwrap_or_else(|e| e.into_inner()) = Some(mixer);
        *SPIRC.lock().unwrap_or_else(|e| e.into_inner()) = Some(Arc::clone(&spirc));
        *PLAYER_EVENT_TX.lock().unwrap_or_else(|e| e.into_inner()) = None;
        *ENGINE_TASKS.lock().unwrap_or_else(|e| e.into_inner()) = Some(staged_tasks);
        with_connection(|c| {
            c.device_id = Some(device_id.clone());
            c.spirc_ready = false;
            c.session_connected = false;
            c.resume_pending = false;
            c.credentials_rejected = false;
            c.last_error = None;
            c.is_active_device = active_device;
        });
    }

    // The production objects and the initial Spirc task are now published. Start the remaining
    // generation tasks only after their globals exist, and append each handle to the owned
    // registry before the next await or fallible setup step. A listener setup failure therefore
    // uses the same async rollback as an activation failure.
    let (event_stop_tx, event_task) = start_player_event_pump(
        current_player().expect("published Player"),
        event_channel,
        current_generation,
    );
    *PLAYER_EVENT_TX.lock().unwrap_or_else(|e| e.into_inner()) = Some(event_stop_tx);
    ENGINE_TASKS
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .as_mut()
        .expect("published task registry")
        .push(event_task);

    let cluster_task = match spawn_cluster_listener(&session, current_generation) {
        Ok(task) => task,
        Err(_) => {
            rollback_installed_generation(current_generation).await;
            installed_guard.disarm();
            return Err(InitializationFailure::Transient);
        }
    };
    ENGINE_TASKS
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .as_mut()
        .expect("published task registry")
        .push(cluster_task);
    ENGINE_TASKS
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .as_mut()
        .expect("published task registry")
        .push(spawn_initial_cluster_fetch(&session, current_generation));
    ENGINE_TASKS
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .as_mut()
        .expect("published task registry")
        .push(spawn_session_health_check(current_generation));
    clear_retired_credentials_cache();

    // A cleanup or newer generation can invalidate the local transaction while the Spirc task
    // was being started. Do not let this attempt announce success or tear down newer globals.
    if !listener_may_act(
        current_generation,
        SESSION_GENERATION.load(Ordering::SeqCst),
    ) || teardown_in_progress()
    {
        rollback_installed_generation(current_generation).await;
        installed_guard.disarm();
        return Err(InitializationFailure::Transient);
    }

    // Rehydrate before announcing readiness. The rebuilt Player has no track
    // loaded, and nothing else will load one: Spirc coming up and the device
    // becoming active only make it *available* to play, not playing. Without this
    // the session returns healthy and silent while Swift still shows the pre-outage
    // position, because IS_PLAYING and the position anchor survive the rebuild.
    //
    // The load comes from Swift. Publishing `resume_pending` with `spirc_ready`
    // still clear tells `PlaybackStore` to issue its `ResumeLoadPlan` targets now;
    // `session_connected` must already be true for those loads to pass
    // `require_session_connected`. Inside this window `load_at_position` returns as
    // soon as Spirc queued the load, so Swift stops at the first queued target (as
    // `resume_via_load` did) and the wait below is the only Playing wait. Swift's
    // session phase stays non-ready until the commit below, so its Web API bootstrap
    // still waits for the rehydrated state.
    //
    // This used to arm a five-second window waiting for a Paused event, on the
    // assumption that the track would load itself via transfer(None) — nothing in
    // this path ever called transfer(None), so the event never came.
    if resume_after_connect {
        if has_resume_identity() {
            let (seq_before, notification) = with_generation_mutation(|| {
                let seq_before = open_rehydration_window_locked(current_generation);
                with_connection(|c| {
                    c.session_connected = true;
                    c.resume_pending = true;
                    c.last_error = None;
                });
                (
                    seq_before,
                    capture_connection_state_notification(current_generation),
                )
            });
            if let Some(notification) = notification {
                deliver_connection_state_notification(notification);
            }

            let outcome = wait_for_rehydration(seq_before, REHYDRATION_WINDOW).await;
            with_generation_mutation(|| {
                if listener_may_act(
                    current_generation,
                    SESSION_GENERATION.load(Ordering::SeqCst),
                ) {
                    with_connection(|c| c.resume_pending = false);
                }
            });
            debug!(
                "[WAKE +{}ms] Rehydrate after reconnect: {:?}",
                elapsed_since_wake_ms(),
                outcome
            );

            if outcome == RehydrationOutcome::NeedsReinit {
                with_connection(|c| c.session_connected = false);
                rollback_installed_generation(current_generation).await;
                installed_guard.disarm();
                return Err(InitializationFailure::Transient);
            }
        } else {
            // Nothing to resume — no saved context or track URI. Reachable when an
            // outage lands between a play command and the player events that record
            // what is playing. The session itself is fine, so failing here would
            // make every later attempt fail identically, forever.
            debug!(
                "[WAKE +{}ms] Rehydrate: nothing to resume",
                elapsed_since_wake_ms()
            );
        }
    }

    // Committing late means this can be reached after something else took over — cleanup,
    // manual retry, or sleep can all invalidate the generation while Swift is loading.
    if !listener_may_act(
        current_generation,
        SESSION_GENERATION.load(Ordering::SeqCst),
    ) || teardown_in_progress()
    {
        rollback_installed_generation(current_generation).await;
        installed_guard.disarm();
        return Err(InitializationFailure::Transient);
    }

    // Single commit-and-publish point: session up, device activation settled, and any requested
    // rehydration window complete. No snapshot in between can announce a half-built engine.
    // Keep the final readiness mutation behind the same short gate as rehydration loads so a
    // command cannot pass its window check while this commit closes that window.
    let Some(Ok(notification)) = with_current_generation_mutation(current_generation, || {
        if teardown_in_progress() {
            return Err(());
        }
        with_connection(|c| {
            c.spirc_ready = true;
            c.session_connected = true;
            c.resume_pending = false;
            c.credentials_rejected = false;
            c.last_error = None;
        });
        Ok(capture_connection_state_notification(current_generation))
    }) else {
        rollback_installed_generation(current_generation).await;
        installed_guard.disarm();
        return Err(InitializationFailure::Transient);
    };
    if let Some(notification) = notification {
        deliver_connection_state_notification(notification);
    }
    installed_guard.disarm();
    Ok(())
}

#[cfg(test)]
mod construction_tests {
    use super::*;

    #[test]
    fn cancelling_staged_construction_stops_its_task_and_session() {
        struct TaskStopped(Option<tokio::sync::oneshot::Sender<()>>);
        impl Drop for TaskStopped {
            fn drop(&mut self) {
                if let Some(sender) = self.0.take() {
                    let _ = sender.send(());
                }
            }
        }

        block_on_export(async {
            let session = Session::new(SessionConfig::default(), None);
            let (started_tx, started_rx) = tokio::sync::oneshot::channel();
            let (stopped_tx, stopped_rx) = tokio::sync::oneshot::channel();
            let task = tokio::spawn(async move {
                let _stopped = TaskStopped(Some(stopped_tx));
                let _ = started_tx.send(());
                std::future::pending::<()>().await;
            });
            started_rx.await.expect("staged task started");
            let staged = StagedGenerationGuard {
                spirc: None,
                session: Some(session.clone()),
                tasks: vec![task],
                armed: true,
            };
            drop(staged);
            assert!(session.is_invalid());
            tokio::time::timeout(Duration::from_secs(2), stopped_rx)
                .await
                .expect("staged task cancellation settles")
                .expect("staged task was dropped");
        })
        .expect("construction cancellation test");
    }

    #[test]
    fn session_shutdown_guard_invalidates_an_unpublished_session_on_drop() {
        let invalid = block_on_export(async {
            let session = Session::new(SessionConfig::default(), None);
            assert!(!session.is_invalid());

            {
                let _guard = SessionShutdownGuard::new(session.clone());
            }

            session.is_invalid()
        })
        .expect("lifecycle test");

        assert!(invalid, "a cancelled construction must close its Session");
    }
}
