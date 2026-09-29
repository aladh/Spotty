use crate::*;

/// Spirc and the compensating Dealer close each get this independent deadline. The pinned
/// Dealer allows three seconds for websocket close; this leaves a scheduling margin.
pub(crate) const SPIRC_GRACEFUL_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(4);

/// A spawned generation task can never detach merely because its next owner is discarded.
/// Keep this protection from spawn through registration, retirement, and every pending join.
pub(crate) struct OwnedTask(JoinHandle<()>);

impl OwnedTask {
    pub(crate) fn new(task: JoinHandle<()>) -> Self {
        Self(task)
    }

    pub(crate) async fn cancel_and_join(mut self) {
        self.0.abort();
        let _ = (&mut self.0).await;
    }
}

impl Drop for OwnedTask {
    fn drop(&mut self) {
        self.0.abort();
    }
}

/// The stop channel and listener have one registration and retirement lifetime.
pub(crate) struct PlayerEventTask {
    stop: mpsc::UnboundedSender<()>,
    task: OwnedTask,
}

impl PlayerEventTask {
    pub(crate) fn from_owned(stop: mpsc::UnboundedSender<()>, task: OwnedTask) -> Self {
        Self { stop, task }
    }

    fn signal_stop(&self) {
        let _ = self.stop.send(());
    }

    pub(crate) async fn cancel_and_join(self) {
        self.signal_stop();
        self.task.cancel_and_join().await;
    }
}

/// Session::drop only releases an Arc; explicit invalidation is required even before Spirc exists.
/// Construction transfers this guard into GenerationResources without disarming it.
pub(crate) struct SessionShutdownGuard {
    session: Session,
}

impl SessionShutdownGuard {
    pub(crate) fn new(session: Session) -> Self {
        Self { session }
    }
}

impl Drop for SessionShutdownGuard {
    fn drop(&mut self) {
        self.session.shutdown();
    }
}

/// Owns a complete generation through construction, publication, and retirement. The sole
/// production constructor requires every concrete object and the explicitly named Spirc task.
/// Dropping an unpublished or rejected owner uses the same bounded drain as normal teardown.
/// Engine accessors only move this value; never destroy it while holding ENGINE.
pub(crate) struct GenerationResources {
    contents: Option<GenerationContents>,
}

// The outer owner can transfer these already-protected contents into asynchronous retirement.
// Field order is intentional on cancellation: abort tasks, invalidate Session, release objects.
struct GenerationContents {
    spirc: Option<SpircOwner>,
    tasks: GenerationTasks,
    session: Option<SessionShutdownGuard>,
    _player: Option<PlayerObserver>,
    _mixer: Option<Arc<SoftMixer>>,
}

struct SpircOwner {
    task: OwnedTask,
    control: Arc<Spirc>,
}

struct GenerationTasks {
    player_events: Option<PlayerEventTask>,
    observers: Vec<OwnedTask>,
}

impl GenerationResources {
    pub(crate) fn new(
        session: SessionShutdownGuard,
        player: PlayerObserver,
        mixer: Arc<SoftMixer>,
        spirc: Arc<Spirc>,
        spirc_task: OwnedTask,
    ) -> Self {
        Self {
            contents: Some(GenerationContents {
                spirc: Some(SpircOwner {
                    task: spirc_task,
                    control: spirc,
                }),
                tasks: GenerationTasks {
                    player_events: None,
                    observers: Vec::new(),
                },
                session: Some(session),
                _player: Some(player),
                _mixer: Some(mixer),
            }),
        }
    }

    pub(crate) fn session(&self) -> Option<&Session> {
        self.contents
            .as_ref()?
            .session
            .as_ref()
            .map(|guard| &guard.session)
    }

    pub(crate) fn spirc(&self) -> Option<&Arc<Spirc>> {
        self.contents
            .as_ref()?
            .spirc
            .as_ref()
            .map(|owner| &owner.control)
    }

    pub(crate) fn add_observer(&mut self, task: OwnedTask) {
        self.contents
            .as_mut()
            .expect("resources have not retired")
            .tasks
            .observers
            .push(task);
    }

    pub(crate) fn set_player_events(
        &mut self,
        task: PlayerEventTask,
    ) -> Result<(), PlayerEventTask> {
        let slot = &mut self
            .contents
            .as_mut()
            .expect("resources have not retired")
            .tasks
            .player_events;
        if slot.is_some() {
            return Err(task);
        }
        *slot = Some(task);
        Ok(())
    }

    /// An unpolled future still owns self and its synchronous fallback. Once polled, the
    /// contents keep task abort and Session invalidation armed throughout all shutdown awaits.
    pub(crate) async fn shutdown(mut self, context: &str) {
        if let Some(contents) = self.contents.take() {
            contents.shutdown(context).await;
        }
    }

    #[cfg(test)]
    pub(crate) fn for_test(session: Option<Session>, tasks: Vec<JoinHandle<()>>) -> Self {
        Self {
            contents: Some(GenerationContents {
                spirc: None,
                tasks: GenerationTasks {
                    player_events: None,
                    observers: tasks.into_iter().map(OwnedTask::new).collect(),
                },
                session: session.map(SessionShutdownGuard::new),
                _player: None,
                _mixer: None,
            }),
        }
    }
}

impl Drop for GenerationResources {
    fn drop(&mut self) {
        if let Some(contents) = self.contents.take() {
            contents.shutdown_sync("generation ownership discarded");
        }
    }
}

impl GenerationContents {
    fn signal_stop(&self) {
        if let Some(pump) = &self.tasks.player_events {
            pump.signal_stop();
        }
        proxy_sink::ProxySink::notify_player_gone();
    }

    async fn shutdown(mut self, context: &str) {
        self.signal_stop();
        if let Some(spirc) = &mut self.spirc {
            drain_spirc_task(
                &mut spirc.task.0,
                || {
                    if spirc.control.shutdown().is_err() {
                        debug!("{}: spirc shutdown could not be queued", context);
                    }
                },
                SPIRC_GRACEFUL_SHUTDOWN_TIMEOUT,
                context,
            )
            .await;
        }

        // A forced Spirc abort can skip its run-loop close. Compensate while Session remains
        // valid so the Dealer joins its websocket tasks before replacement. This is a separate
        // four-second deadline, not a total four-second shutdown budget.
        if let Some(guard) = &self.session {
            if tokio::time::timeout(
                SPIRC_GRACEFUL_SHUTDOWN_TIMEOUT,
                guard.session.dealer().close(),
            )
            .await
            .is_err()
            {
                debug!(
                    "{}: dealer close timed out; continuing with bounded task abort",
                    context
                );
            }
        }

        // Abort every child before joining any of them. Retain each handle in its owner across
        // the await so cancellation cannot detach later children. The named Spirc task is
        // already joined and is never accidentally selected from registration order.
        if let Some(pump) = &self.tasks.player_events {
            pump.task.0.abort();
        }
        for task in &self.tasks.observers {
            task.0.abort();
        }
        if let Some(pump) = &mut self.tasks.player_events {
            let _ = (&mut pump.task.0).await;
        }
        for task in &mut self.tasks.observers {
            let _ = (&mut task.0).await;
        }
        // Field destruction invalidates Session only after every owned join has settled.
    }

    fn shutdown_sync(self, context: &str) {
        if let Ok(handle) = tokio::runtime::Handle::try_current() {
            if handle.runtime_flavor() == tokio::runtime::RuntimeFlavor::MultiThread {
                tokio::task::block_in_place(|| handle.block_on(self.shutdown(context)));
            } else {
                // Blocking a current-thread executor would prevent the owned tasks from
                // progressing. Signal now; protected field destruction aborts and invalidates.
                self.signal_stop();
                if let Some(spirc) = &self.spirc {
                    let _ = spirc.control.shutdown();
                }
            }
        } else {
            let _ = block_on_export(self.shutdown(context));
        }
    }
}

/// Only the lifecycle owner retires generation resources. Child tasks request recovery instead;
/// they never call this helper and therefore cannot join themselves. Extraction releases ENGINE
/// before callbacks, awaits, Session invalidation, or Player's blocking destructor can run.
pub(crate) async fn teardown_engine_resources(context: &str) {
    if let Some(resources) = take_engine_resources() {
        resources.shutdown(context).await;
    }
}

/// Queues a Spirc shutdown before waiting for its owned task, with an injectable timeout for
/// deterministic lifecycle tests. Keeping this sequencing in one helper prevents a future
/// teardown path from aborting the task before the upstream dealer receives its close request.
async fn drain_spirc_task(
    spirc_task: &mut JoinHandle<()>,
    request_shutdown: impl FnOnce(),
    timeout: Duration,
    context: &str,
) {
    request_shutdown();
    match tokio::time::timeout(timeout, &mut *spirc_task).await {
        Ok(Ok(())) => {
            debug!("{}: Spirc task closed gracefully", context);
        }
        Ok(Err(_)) => {
            debug!("{}: Spirc task exited with a join failure", context);
        }
        Err(_) => {
            debug!(
                "{}: Spirc graceful shutdown timed out; aborting task",
                context
            );
            spirc_task.abort();
            let _ = (&mut *spirc_task).await;
        }
    }
}

#[cfg(test)]
mod teardown_tests {
    use super::*;
    use std::future::pending;
    use std::sync::atomic::AtomicBool;

    struct Stopped(Option<tokio::sync::oneshot::Sender<()>>);

    impl Drop for Stopped {
        fn drop(&mut self) {
            if let Some(sender) = self.0.take() {
                let _ = sender.send(());
            }
        }
    }

    async fn parked_task() -> (JoinHandle<()>, tokio::sync::oneshot::Receiver<()>) {
        let (started_tx, started_rx) = tokio::sync::oneshot::channel();
        let (stopped_tx, stopped_rx) = tokio::sync::oneshot::channel();
        let task = tokio::spawn(async move {
            let _stopped = Stopped(Some(stopped_tx));
            let _ = started_tx.send(());
            pending::<()>().await;
        });
        tokio::time::timeout(Duration::from_secs(2), started_rx)
            .await
            .expect("task starts")
            .expect("task signaled start");
        (task, stopped_rx)
    }

    #[test]
    fn spirc_retirement_keeps_children_and_session_until_grace_or_cancellation() {
        let _guard = lock_lifecycle_test_globals();
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .start_paused(true)
            .build()
            .unwrap();
        runtime.block_on(async {
            for cancel in [false, true] {
                let session = Session::new(SessionConfig::default(), None);
                let (observer, mut observer_stopped) = parked_task().await;
                let (spirc, mut spirc_stopped) = parked_task().await;
                let mut resources =
                    GenerationResources::for_test(Some(session.clone()), vec![observer]);
                // An actual closed Spirc command channel plus a stalled task exercises the
                // production grace path without Spotify, a player thread, or real-time delay.
                resources.contents.as_mut().unwrap().spirc = Some(SpircOwner {
                    task: OwnedTask::new(spirc),
                    control: Arc::new(librespot_connect::SpottyTransportFixture::closed_handle()),
                });
                let mut retirement = Box::pin(resources.shutdown("parked Spirc retirement"));
                assert!(futures_util::poll!(retirement.as_mut()).is_pending());
                assert!(!session.is_invalid());
                assert_eq!(
                    observer_stopped.try_recv(),
                    Err(tokio::sync::oneshot::error::TryRecvError::Empty)
                );
                assert_eq!(
                    spirc_stopped.try_recv(),
                    Err(tokio::sync::oneshot::error::TryRecvError::Empty)
                );
                if cancel {
                    drop(retirement);
                } else {
                    tokio::time::advance(SPIRC_GRACEFUL_SHUTDOWN_TIMEOUT).await;
                    retirement.await;
                }
                assert!(session.is_invalid());
                for stopped in [spirc_stopped, observer_stopped] {
                    tokio::time::timeout(Duration::from_secs(2), stopped)
                        .await
                        .expect("retired task settles")
                        .expect("task stopped");
                }
            }
        });
    }

    #[test]
    fn cancellation_on_current_thread_aborts_children_and_invalidates_session() {
        let _guard = lock_lifecycle_test_globals();
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        runtime.block_on(async {
            for poll_retirement in [false, true] {
                let session = Session::new(SessionConfig::default(), None);
                let (first, first_stopped) = parked_task().await;
                let (second, second_stopped) = parked_task().await;
                let resources =
                    GenerationResources::for_test(Some(session.clone()), vec![first, second]);
                if poll_retirement {
                    let mut retirement = Box::pin(resources.shutdown("cancel pending retirement"));
                    // The aborted children cannot settle until this executor gets control back.
                    // Cancel precisely while the real shutdown path is joining its first child.
                    assert!(futures_util::poll!(retirement.as_mut()).is_pending());
                    drop(retirement);
                } else {
                    drop(resources);
                }
                assert!(session.is_invalid());
                for stopped in [first_stopped, second_stopped] {
                    tokio::time::timeout(Duration::from_secs(2), stopped)
                        .await
                        .expect("current-thread cancellation progresses")
                        .expect("task stopped");
                }
            }
        });
    }

    #[test]
    fn dropping_resources_outside_tokio_drains_before_returning() {
        let _guard = lock_lifecycle_test_globals();
        let (resources, session, mut stopped) = block_on_export(async {
            let session = Session::new(SessionConfig::default(), None);
            let (task, stopped) = parked_task().await;
            (
                GenerationResources::for_test(Some(session.clone()), vec![task]),
                session,
                stopped,
            )
        })
        .unwrap();
        drop(resources);
        assert!(session.is_invalid());
        assert_eq!(
            stopped.try_recv(),
            Ok(()),
            "the synchronous fallback must join before returning"
        );
    }

    #[test]
    fn unpolled_retirement_stops_tasks_and_invalidates_session() {
        let _guard = lock_lifecycle_test_globals();
        block_on_export(async {
            let session = Session::new(SessionConfig::default(), None);
            let (task, mut stopped_rx) = parked_task().await;
            let emergency_abort = task.abort_handle();
            let resources = GenerationResources::for_test(Some(session.clone()), vec![task]);
            drop(resources.shutdown("unpolled retirement test"));
            let invalidated = session.is_invalid();
            let settled = tokio::time::timeout(Duration::from_secs(2), &mut stopped_rx).await;
            // Restore the fixture even on the old implementation, which detaches this task.
            emergency_abort.abort();
            session.shutdown();
            assert!(
                settled.is_ok(),
                "discarding cleanup must not detach owned tasks"
            );
            assert!(
                invalidated,
                "discarding cleanup must invalidate the owned Session"
            );
        })
        .expect("unpolled retirement test");
    }

    #[test]
    fn graceful_teardown_requests_shutdown_before_joining_spirc() {
        let shutdown_requested = Arc::new(AtomicBool::new(false));
        let task_finished = Arc::new(AtomicBool::new(false));

        block_on_export(async {
            let task_shutdown_requested = Arc::clone(&shutdown_requested);
            let task_finished = Arc::clone(&task_finished);
            let mut task = tokio::spawn(async move {
                while !task_shutdown_requested.load(Ordering::SeqCst) {
                    tokio::task::yield_now().await;
                }
                task_finished.store(true, Ordering::SeqCst);
            });

            let shutdown_requested = Arc::clone(&shutdown_requested);
            drain_spirc_task(
                &mut task,
                move || shutdown_requested.store(true, Ordering::SeqCst),
                Duration::from_secs(1),
                "graceful teardown test",
            )
            .await;
        })
        .expect("graceful teardown test");

        assert!(
            task_finished.load(Ordering::SeqCst),
            "Spirc must receive shutdown before its task is joined"
        );
    }

    #[test]
    fn stalled_spirc_teardown_aborts_and_joins_within_deadline() {
        struct DropProbe(Arc<AtomicBool>);
        impl Drop for DropProbe {
            fn drop(&mut self) {
                self.0.store(true, Ordering::SeqCst);
            }
        }

        let task_dropped = Arc::new(AtomicBool::new(false));
        block_on_export(async {
            let task_dropped_by_task = Arc::clone(&task_dropped);
            let (started_tx, started_rx) = tokio::sync::oneshot::channel();
            let mut task = tokio::spawn(async move {
                let _probe = DropProbe(task_dropped_by_task);
                started_tx.send(()).unwrap();
                pending::<()>().await;
            });
            started_rx.await.unwrap();

            drain_spirc_task(
                &mut task,
                || {},
                Duration::from_millis(20),
                "stalled teardown test",
            )
            .await;
        })
        .expect("stalled teardown test");

        assert!(
            task_dropped.load(Ordering::SeqCst),
            "a stalled Spirc task must be aborted and joined"
        );
    }
    #[test]
    #[ignore = "wall-clock measurement of the production four-second graceful deadline"]
    fn measure_stalled_spirc_task_deadline() {
        let mut samples = Vec::new();
        block_on_export(async {
            for _ in 0..3 {
                let (started_tx, started_rx) = tokio::sync::oneshot::channel();
                let mut task = tokio::spawn(async move {
                    started_tx.send(()).unwrap();
                    pending::<()>().await;
                });
                started_rx.await.unwrap();
                let started = std::time::Instant::now();
                drain_spirc_task(
                    &mut task,
                    || {},
                    SPIRC_GRACEFUL_SHUTDOWN_TIMEOUT,
                    "injected stalled Spirc task",
                )
                .await;
                samples.push(started.elapsed().as_secs_f64() * 1_000.0);
                assert!(task.is_finished());
            }
        })
        .unwrap();
        if let Ok(path) = std::env::var("SPOTTY_STALLED_SHUTDOWN_REPORT") {
            std::fs::write(
                path,
                serde_json::to_vec_pretty(&serde_json::json!({
                    "fault": "parked task ignores shutdown request; no actual Spirc or dealer",
                    "deadlineMilliseconds": SPIRC_GRACEFUL_SHUTDOWN_TIMEOUT.as_millis(),
                    "milliseconds": samples
                }))
                .unwrap(),
            )
            .unwrap();
        }
    }
}
