use super::*;
use librespot_playback::player::Player;
/// Builds librespot's own Player, decoding in-process and delivering PCM through `proxy_sink.rs`.
fn create_librespot_player(session: &Session) -> Arc<Player> {
    let player_config = PlayerConfig {
        bitrate: Bitrate::Bitrate320,
        gapless: true,
        position_update_interval: Some(Duration::from_millis(200)),
        ..PlayerConfig::default()
    };
    let audio_format = AudioFormat::default();

    // Send original PCM to the renderer. The mixer still tracks reported Connect volume.
    Player::new(
        player_config,
        session.clone(),
        Box::new(NoOpVolume),
        move || mk_proxy_sink(None, audio_format),
    )
}

/// Rolls back an installed generation only if it still owns the engine state.
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
    if let Some(resources) = take_engine_resources_owned(generation) {
        resources.shutdown("initialization rollback").await;
    }
    if with_connection_owned(generation, |c| {
        c.spirc_ready = false;
        c.session_connected = false;
        c.resume_pending = false;
        c.device_id = None;
        c.is_active_device = false;
    })
    .is_err()
    {
        debug!(
            "initialization rollback: generation {} is stale",
            generation
        );
        return;
    }
    notify_connection_state_change();
}

/// Abandons a published generation: tears it down if it is still ours, disarms the cancellation
/// guard, and reports the transient failure the caller returns.
async fn abandon_installed_generation(
    generation: u64,
    guard: &mut InstalledGenerationGuard,
) -> InitializationFailure {
    rollback_installed_generation(generation).await;
    guard.disarm();
    InitializationFailure::Transient
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
    fn publish(
        generation: u64,
        resources: GenerationResources,
        device_id: String,
        active_device: bool,
    ) -> Result<Self, GenerationResources> {
        let _store = enter_store_section();
        publish_engine_generation(generation, resources, device_id, active_device)?;
        Ok(Self {
            generation,
            armed: true,
        })
    }

    async fn attach_player_events(&self, task: PlayerEventTask) -> Result<(), StaleGeneration> {
        if let Err(refused) = register_player_events(self.generation, task) {
            refused.cancel_and_join().await;
            return Err(StaleGeneration);
        }
        Ok(())
    }

    async fn attach_observer(&self, task: OwnedTask) -> Result<(), StaleGeneration> {
        if let Err(refused) = register_engine_observer(self.generation, task) {
            refused.cancel_and_join().await;
            return Err(StaleGeneration);
        }
        Ok(())
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
        // Taking under the same generation check closes the check-then-take interval.
        // The returned owner drains and releases every object outside ENGINE.
        drop(take_engine_resources_owned(self.generation));
        let _ = with_connection_owned(self.generation, |c| {
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
pub(crate) fn with_initialization_failure_ownership<T>(
    generation: u64,
    failure: InitializationFailure,
    recovery: Option<&RecoveryLease>,
    mutation: impl FnOnce() -> T,
) -> Option<T> {
    with_current_generation_mutation(generation, || {
        if failure != InitializationFailure::CredentialsRejected
            || teardown_in_progress()
            || recovery.is_some_and(RecoveryLease::is_cancelled)
        {
            return None;
        }
        Some(mutation())
    })
    .flatten()
}

fn publish_initialization_failure(
    generation: u64,
    failure: InitializationFailure,
    recovery: Option<&RecoveryLease>,
) {
    // Cancellation and generation invalidation share this gate. Capture notification under it,
    // then release it before delivering the observation.
    let notification = with_initialization_failure_ownership(generation, failure, recovery, || {
        clear_resolved_credentials();
        mark_credentials_rejected();
        capture_connection_state_notification(generation)
    });
    if let Some(notification) = notification {
        deliver_connection_state_notification(notification);
    }
}

/// Publishes the session after activation and any reconnect rehydration settle.
pub(crate) async fn build_player_owned(
    access_token: Option<&str>,
    activate_after_connect: bool,
    resume_after_connect: bool,
    recovery: Option<&RecoveryLease>,
) -> Result<(), InitializationFailure> {
    let stopped = || teardown_in_progress() || recovery.is_some_and(RecoveryLease::is_cancelled);
    if stopped() {
        return Err(InitializationFailure::Transient);
    }
    let current_generation = tokio::task::spawn_blocking(invalidate_cluster_generation)
        .await
        .map_err(|_| InitializationFailure::Transient)?;
    LAST_BUILD_GENERATION.store(current_generation, Ordering::SeqCst);
    debug!(
        "[WAKE +{}ms] build_player_async starting, generation={}",
        elapsed_since_wake_ms(),
        current_generation
    );

    let resume_targets = if resume_after_connect {
        capture_resume_targets()
    } else {
        Vec::new()
    };

    let device_id = configured_device_id().ok_or(InitializationFailure::Transient)?;
    let (session, credentials) =
        create_session(&device_id, access_token).map_err(|_| InitializationFailure::Transient)?;
    let session_guard = SessionShutdownGuard::new(session.clone());

    // Create new mixer
    let mixer_config = MixerConfig::default();
    let mixer: Arc<SoftMixer> =
        Arc::new(SoftMixer::open(mixer_config).map_err(|_| InitializationFailure::Transient)?);

    // Create new player - must be created with the new session because Player is
    // tightly coupled to Session's ChannelManager for decryption key requests
    let player = create_librespot_player(&session);
    let observer = player.observer();
    // Subscribe before Spirc can emit startup or activation events, but defer applying them
    // until the generation is installed. Dropping a failed local build drops this receiver too.
    let event_channel = observer.subscribe();
    let (spirc, spirc_task) =
        match create_spirc(&session, &credentials, player, mixer.clone()).await {
            Ok(resources) => resources,
            Err(failure) => {
                publish_initialization_failure(current_generation, failure, recovery);
                return Err(failure);
            }
        };
    let event_observer = observer.clone();
    let staged =
        GenerationResources::new(session_guard, observer, mixer, spirc.clone(), spirc_task);

    if stopped() {
        staged.shutdown("staged construction rollback").await;
        return Err(InitializationFailure::Transient);
    }

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
                staged.shutdown("staged construction rollback").await;
                publish_initialization_failure(current_generation, failure, recovery);
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
    ) || stopped()
    {
        staged.shutdown("staged construction rollback").await;
        return Err(InitializationFailure::Transient);
    }

    // Publication transfers the same protected owner and returns an armed installation guard.
    // There is no tuple of unguarded handles or separate Session disarm at this boundary.
    let mut installed_guard = match InstalledGenerationGuard::publish(
        current_generation,
        staged,
        device_id,
        active_device,
    ) {
        Ok(guard) => guard,
        Err(rejected) => {
            debug!(
                "Publication refused: generation {} was superseded or occupied",
                current_generation
            );
            rejected.shutdown("refused construction publication").await;
            return Err(InitializationFailure::Transient);
        }
    };

    // Every spawn returns an owning value. Registration either adopts it atomically or joins
    // its cancellation outside ENGINE; the installation guard stays armed during that await.
    let event_task = start_player_event_pump(event_observer, event_channel, current_generation);
    if installed_guard
        .attach_player_events(event_task)
        .await
        .is_err()
    {
        return Err(abandon_installed_generation(current_generation, &mut installed_guard).await);
    }

    let cluster_task = match spawn_cluster_listener(&session, current_generation) {
        Ok(task) => task,
        Err(_) => {
            return Err(
                abandon_installed_generation(current_generation, &mut installed_guard).await,
            );
        }
    };
    if installed_guard.attach_observer(cluster_task).await.is_err()
        || installed_guard
            .attach_observer(spawn_initial_cluster_fetch(&session, current_generation))
            .await
            .is_err()
        || installed_guard
            .attach_observer(spawn_session_health_check(current_generation))
            .await
            .is_err()
    {
        return Err(abandon_installed_generation(current_generation, &mut installed_guard).await);
    }
    clear_retired_credentials_cache();

    // A cleanup or newer generation can invalidate the local transaction while the Spirc task
    // was being started. Do not let this attempt announce success or tear down newer globals.
    if !listener_may_act(
        current_generation,
        SESSION_GENERATION.load(Ordering::SeqCst),
    ) || stopped()
    {
        rollback_installed_generation(current_generation).await;
        installed_guard.disarm();
        return Err(InitializationFailure::Transient);
    }

    // The rebuild owns both load submission and its confirmation window.
    if !resume_targets.is_empty() {
        let Some((seq_before, notification)) =
            with_current_generation_mutation(current_generation, || {
                let seq_before = playing_event_stamp().sequence;
                with_connection(|connection| {
                    connection.session_connected = true;
                    connection.resume_pending = true;
                    connection.last_error = None;
                });
                (
                    seq_before,
                    capture_connection_state_notification(current_generation),
                )
            })
        else {
            return Err(
                abandon_installed_generation(current_generation, &mut installed_guard).await,
            );
        };
        deliver_connection_state_notification(notification);

        let outcome = match queue_rehydration(current_generation, &spirc, resume_targets) {
            Ok(()) => {
                wait_for_rehydration(current_generation, seq_before, REHYDRATION_WINDOW).await
            }
            Err(CommandError::NeedsReinitialization) => RehydrationOutcome::NeedsReinit,
            _ => RehydrationOutcome::TimedOut,
        };
        with_generation_mutation(|| {
            let _ = with_connection_owned(current_generation, |c| c.resume_pending = false);
        });
        debug!(
            "[WAKE +{}ms] Rehydrate after reconnect: {:?}",
            elapsed_since_wake_ms(),
            outcome
        );
        if outcome == RehydrationOutcome::NeedsReinit {
            let _ = with_connection_owned(current_generation, |c| c.session_connected = false);
            return Err(
                abandon_installed_generation(current_generation, &mut installed_guard).await,
            );
        }
    }

    // Committing late means this can be reached after something else took over — cleanup,
    // manual retry, or sleep can all invalidate the generation while the load is pending.
    if !listener_may_act(
        current_generation,
        SESSION_GENERATION.load(Ordering::SeqCst),
    ) || stopped()
    {
        return Err(abandon_installed_generation(current_generation, &mut installed_guard).await);
    }

    // Single commit-and-publish point: session up, device activation settled, and any requested
    // rehydration window complete. No snapshot in between can announce a half-built engine.
    // Keep the final readiness mutation behind the same short gate as rehydration loads so a
    // command cannot pass its window check while this commit closes that window. The readiness
    // write itself names this generation, so a cleanup that wins the gate cannot be overwritten.
    let Some(Ok(notification)) = with_current_generation_mutation(current_generation, || {
        if stopped() {
            return Err(());
        }
        with_connection_owned(current_generation, |c| {
            c.spirc_ready = true;
            c.session_connected = true;
            c.resume_pending = false;
            c.credentials_rejected = false;
            c.last_error = None;
        })
        .map_err(|_| ())?;
        Ok(capture_connection_state_notification(current_generation))
    }) else {
        return Err(abandon_installed_generation(current_generation, &mut installed_guard).await);
    };
    deliver_connection_state_notification(notification);
    installed_guard.disarm();
    Ok(())
}

#[cfg(test)]
mod construction_tests {
    use super::*;

    struct RestoreEngine {
        generation: u64,
        resources: Option<GenerationResources>,
        connection: ConnectionState,
    }

    impl RestoreEngine {
        fn capture() -> Self {
            Self {
                resources: take_engine_resources(),
                connection: with_connection(std::mem::take),
                generation: set_session_generation_for_test(41),
            }
        }
    }

    impl Drop for RestoreEngine {
        fn drop(&mut self) {
            drop(replace_engine_resources_for_test(self.resources.take()));
            with_connection(|connection| *connection = self.connection.clone());
            set_session_generation_for_test(self.generation);
        }
    }

    async fn parked_registration() -> (OwnedTask, tokio::sync::oneshot::Receiver<()>) {
        struct Stopped(Option<tokio::sync::oneshot::Sender<()>>);
        impl Drop for Stopped {
            fn drop(&mut self) {
                if let Some(sender) = self.0.take() {
                    let _ = sender.send(());
                }
            }
        }
        let (started_tx, started_rx) = tokio::sync::oneshot::channel();
        let (stopped_tx, stopped_rx) = tokio::sync::oneshot::channel();
        let task = OwnedTask::new(tokio::spawn(async move {
            let _stopped = Stopped(Some(stopped_tx));
            let _ = started_tx.send(());
            std::future::pending::<()>().await;
        }));
        tokio::time::timeout(Duration::from_secs(2), started_rx)
            .await
            .expect("registration task starts")
            .expect("task signaled start");
        (task, stopped_rx)
    }

    #[test]
    fn publication_rejection_retires_candidate_and_preserves_installed_generation() {
        let _guard = lock_lifecycle_test_globals();
        let _restore = RestoreEngine::capture();
        block_on_playback(async {
            let current = Session::new(SessionConfig::default(), None);
            let installed = InstalledGenerationGuard::publish(
                41,
                GenerationResources::for_test(Some(current.clone()), vec![]),
                "current".into(),
                true,
            )
            .unwrap_or_else(|_| panic!("empty current slot accepts publication"));
            for rejected_generation in [40, 41] {
                let candidate = Session::new(SessionConfig::default(), None);
                let (task, mut stopped) = parked_registration().await;
                let mut resources = GenerationResources::for_test(Some(candidate.clone()), vec![]);
                resources.add_observer(task);
                let rejected = match InstalledGenerationGuard::publish(
                    rejected_generation,
                    resources,
                    "rejected".into(),
                    false,
                ) {
                    Err(resources) => resources,
                    Ok(_) => panic!("stale or occupied publication must be refused"),
                };
                drop(rejected);
                assert!(candidate.is_invalid());
                assert_eq!(stopped.try_recv(), Ok(()));
                assert!(!current.is_invalid());
                assert_eq!(
                    with_connection(|c| c.device_id.clone()).as_deref(),
                    Some("current")
                );
                assert!(with_connection(|c| c.is_active_device));
            }
            drop(installed);
            assert!(current.is_invalid());
            assert!(current_session().is_none());
        })
        .unwrap();
    }

    #[test]
    fn refused_children_are_joined_and_stale_installation_cannot_retire_replacement() {
        let _guard = lock_lifecycle_test_globals();
        let _restore = RestoreEngine::capture();
        block_on_playback(async {
            let current = Session::new(SessionConfig::default(), None);
            let installed = InstalledGenerationGuard::publish(
                41,
                GenerationResources::for_test(Some(current.clone()), vec![]),
                "current".into(),
                true,
            )
            .unwrap_or_else(|_| panic!("current generation installs"));
            let (task, mut accepted_stopped) = parked_registration().await;
            let (stop, _receiver) = mpsc::unbounded_channel();
            installed
                .attach_player_events(PlayerEventTask::from_owned(stop, task))
                .await
                .unwrap();

            let (duplicate, mut duplicate_stopped) = parked_registration().await;
            let (stop, _receiver) = mpsc::unbounded_channel();
            assert!(
                tokio::time::timeout(
                    Duration::from_secs(2),
                    installed.attach_player_events(PlayerEventTask::from_owned(stop, duplicate),)
                )
                .await
                .unwrap()
                .is_err()
            );
            assert_eq!(duplicate_stopped.try_recv(), Ok(()));
            assert_eq!(
                accepted_stopped.try_recv(),
                Err(tokio::sync::oneshot::error::TryRecvError::Empty)
            );

            let replacement_generation = advance_session_generation();
            take_engine_resources()
                .unwrap()
                .shutdown("replace test generation")
                .await;
            assert_eq!(accepted_stopped.try_recv(), Ok(()));
            assert!(current.is_invalid());
            let replacement_session = Session::new(SessionConfig::default(), None);
            let replacement = InstalledGenerationGuard::publish(
                replacement_generation,
                GenerationResources::for_test(Some(replacement_session.clone()), vec![]),
                "replacement".into(),
                false,
            )
            .unwrap_or_else(|_| panic!("replacement generation installs"));

            let (late_pump, mut late_pump_stopped) = parked_registration().await;
            let (stop, _receiver) = mpsc::unbounded_channel();
            assert!(
                tokio::time::timeout(
                    Duration::from_secs(2),
                    installed.attach_player_events(PlayerEventTask::from_owned(stop, late_pump),)
                )
                .await
                .unwrap()
                .is_err()
            );
            assert_eq!(late_pump_stopped.try_recv(), Ok(()));
            let (late_observer, mut late_observer_stopped) = parked_registration().await;
            assert!(
                tokio::time::timeout(
                    Duration::from_secs(2),
                    installed.attach_observer(late_observer)
                )
                .await
                .unwrap()
                .is_err()
            );
            assert_eq!(late_observer_stopped.try_recv(), Ok(()));

            drop(installed);
            assert!(!replacement_session.is_invalid());
            assert_eq!(
                with_connection(|c| c.device_id.clone()).as_deref(),
                Some("replacement")
            );
            drop(replacement);
            assert!(replacement_session.is_invalid());
        })
        .unwrap();
    }

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

        block_on_playback(async {
            let session = Session::new(SessionConfig::default(), None);
            let (started_tx, started_rx) = tokio::sync::oneshot::channel();
            let (stopped_tx, stopped_rx) = tokio::sync::oneshot::channel();
            let task = tokio::spawn(async move {
                let _stopped = TaskStopped(Some(stopped_tx));
                let _ = started_tx.send(());
                std::future::pending::<()>().await;
            });
            started_rx.await.expect("staged task started");
            let staged = GenerationResources::for_test(Some(session.clone()), vec![task]);
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
        let invalid = block_on_playback(async {
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
