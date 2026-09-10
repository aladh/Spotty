use crate::*;

/// Gives the retained Spirc task enough time to process `Shutdown` and close its dealer before
/// the lifecycle owner falls back to aborting it. The pinned librespot dealer uses a three-second
/// websocket-close deadline, so this leaves a small scheduling margin while keeping teardown
/// bounded when a network operation is stuck.
pub(crate) const SPIRC_GRACEFUL_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(4);

/// Handles removed from the global registry by the lifecycle owner.
///
/// Taking the four slots through one helper keeps normal teardown and cancellation rollback on
/// the same ownership path. Callers must signal `stop_tx` and drain `tasks` before dropping the
/// objects they retain.
pub(crate) struct EngineResources {
    pub(crate) stop_tx: Option<mpsc::UnboundedSender<()>>,
    pub(crate) spirc: Option<Arc<Spirc>>,
    pub(crate) session: Option<Session>,
    pub(crate) tasks: Vec<JoinHandle<()>>,
}

pub(crate) fn take_engine_resources() -> EngineResources {
    let stop_tx = PLAYER_EVENT_TX
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .take();
    let spirc = SPIRC.lock().unwrap_or_else(|e| e.into_inner()).take();
    let session = SESSION.lock().unwrap_or_else(|e| e.into_inner()).take();
    let tasks = ENGINE_TASKS
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .take()
        .unwrap_or_default();
    EngineResources {
        stop_tx,
        spirc,
        session,
        tasks,
    }
}

/// Tears down the current generation's owned resources.
///
/// The caller must hold the lifecycle lock and the store section. Every task handle is taken
/// before cancellation and awaited without any global mutex guard held. This helper is called by
/// the lifecycle owner only; generation child tasks request recovery, but never tear themselves
/// down, so it cannot await or abort its own handle.
pub(crate) async fn teardown_engine_resources(context: &str) {
    let resources = take_engine_resources();
    if let Some(tx) = resources.stop_tx {
        let _ = tx.send(());
    }

    // The Session is taken before awaiting so the task registry and object slots have one owner.
    // It is explicitly invalidated after the child tasks stop, before the last local clone is
    // dropped; dropping Session alone does not close librespot's channels.
    let spirc = resources.spirc;
    let session = resources.session;

    // The Spirc task is the first handle published for every generation. Let it process the
    // shutdown command before touching the abort path so its run loop reaches dealer.close().
    // Remaining listeners are still force-stopped below after the Spirc owner has released the
    // dealer. The task list is taken before the first await so a late task completion cannot race
    // a new generation's publication.
    shutdown_spirc_and_tasks(spirc.as_ref(), session.as_ref(), resources.tasks, context).await;

    // The shutdown helper has already invalidated Session and notified the native renderer before
    // its first await. Drop the concrete objects only after all owned tasks have drained.
    *PLAYER.lock().unwrap_or_else(|e| e.into_inner()) = None;

    // Drop the Spirc, Mixer and Session only after their tasks have stopped; those tasks retain
    // clones of all three objects.
    drop(spirc);
    *MIXER.lock().unwrap_or_else(|e| e.into_inner()) = None;
    drop(session);
}

/// Gracefully stops a generation's Spirc task, then drains all remaining child tasks.
///
/// `ENGINE_TASKS` deliberately stores the Spirc handle first, immediately followed by the player
/// event pump, cluster listener, bootstrap fetch, and health check handles. The first handle is
/// therefore the only one allowed to perform the upstream dealer close; all other tasks are
/// aborted and joined once that owner has finished. A timeout is required because `SpircTask`
/// can be waiting on an upstream request while processing `Shutdown`.
pub(crate) async fn shutdown_spirc_and_tasks(
    spirc: Option<&Arc<Spirc>>,
    session: Option<&Session>,
    tasks: Vec<JoinHandle<()>>,
    context: &str,
) {
    // Keep the handles in an owner while any await below is pending. A cancelled rollback must
    // abort tasks that have not yet been joined; moving them into a future and dropping that
    // future would otherwise detach Tokio tasks into the next generation.
    let mut owned_tasks = OwnedTaskHandles { handles: tasks };
    let spirc_task_present = spirc.is_some() && !owned_tasks.handles.is_empty();

    // Both cleanup callbacks and Session invalidation happen before the first await. If this
    // helper is cancelled while waiting for the dealer or a child task, no live renderer or AP
    // session can survive merely because the caller's future was dropped.
    proxy_sink::ProxySink::notify_player_gone();
    let _session_shutdown_guard = session.cloned().map(SessionShutdownGuard::new);

    if let Some(spirc) = spirc {
        if let Some(spirc_task) = owned_tasks.handles.first_mut() {
            drain_spirc_task(
                spirc_task,
                || {
                    if spirc.shutdown().is_err() {
                        debug!("{}: spirc shutdown could not be queued", context);
                    }
                },
                SPIRC_GRACEFUL_SHUTDOWN_TIMEOUT,
                context,
            )
            .await;
        } else if spirc.shutdown().is_err() {
            debug!("{}: spirc shutdown could not be queued", context);
        }
    }

    // If the Spirc task was forced down, its run-loop never reached the upstream
    // `dealer.close()` at the end of `SpircTask::run`. Close the manager explicitly before the
    // Session is invalidated so its websocket task is joined rather than retained by
    // `TimeoutOnDrop` after this generation has been replaced. The manager's public close API
    // has no error result and delegates to the pinned dealer's websocket tasks, so keep this
    // compensating close bounded by the same four-second lifecycle deadline.
    if let Some(session) = session {
        if tokio::time::timeout(SPIRC_GRACEFUL_SHUTDOWN_TIMEOUT, session.dealer().close())
            .await
            .is_err()
        {
            debug!(
                "{}: dealer close timed out; continuing with bounded task abort",
                context
            );
        }
    }

    let remaining_tasks = if spirc_task_present {
        &mut owned_tasks.handles[1..]
    } else {
        &mut owned_tasks.handles[..]
    };
    for task in remaining_tasks.iter() {
        task.abort();
    }
    for task in remaining_tasks.iter_mut() {
        let _ = (&mut *task).await;
    }
}

/// Owns task handles while a graceful teardown future is awaiting.
///
/// The normal path joins every handle before this is dropped. If cancellation interrupts a
/// dealer close or join, the `Drop` fallback still aborts each handle, so no task is detached
/// merely because an async rollback was cancelled.
struct OwnedTaskHandles {
    handles: Vec<JoinHandle<()>>,
}

impl Drop for OwnedTaskHandles {
    fn drop(&mut self) {
        for task in &self.handles {
            task.abort();
        }
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

/// Synchronous fallback used only by cancellation guards whose `Drop` cannot be async.
///
/// Guard drops happen on the owned runtime in production. `block_in_place` lets this short,
/// bounded drain run to completion without detaching the Spirc task and allowing a newer
/// generation to overlap the old dealer. If a guard is dropped on a current-thread runtime,
/// it signals Spirc and aborts handles because blocking that runtime would deadlock its tasks.
/// A drop outside Tokio uses the process runtime to drain the same bounded cleanup.
pub(crate) fn shutdown_spirc_and_tasks_sync(
    spirc: Option<&Arc<Spirc>>,
    session: Option<&Session>,
    tasks: Vec<JoinHandle<()>>,
    context: &str,
) {
    let spirc = spirc.cloned();
    let session = session.cloned();
    if let Ok(handle) = tokio::runtime::Handle::try_current() {
        if handle.runtime_flavor() == tokio::runtime::RuntimeFlavor::MultiThread {
            tokio::task::block_in_place(|| {
                handle.block_on(shutdown_spirc_and_tasks(
                    spirc.as_ref(),
                    session.as_ref(),
                    tasks,
                    context,
                ));
            });
            return;
        }

        // A current-thread runtime cannot make progress while Drop blocks its only worker. The
        // production runtime is multi-threaded; preserve its bounded cancellation guarantee and
        // use the synchronous signal/abort fallback for an embedding current-thread executor.
        proxy_sink::ProxySink::notify_player_gone();
        if let Some(spirc) = spirc.as_ref() {
            let _ = spirc.shutdown();
        }
        for task in tasks {
            task.abort();
        }
        return;
    }

    // A guard normally drops on the owned runtime, but a caller may discard a staged value on a
    // non-runtime thread. Run the same bounded drain on the process runtime instead of detaching
    // its handles; this path is safe because there is no current Tokio runtime to re-enter.
    let _ = block_on_export(shutdown_spirc_and_tasks(
        spirc.as_ref(),
        session.as_ref(),
        tasks,
        context,
    ));
}

#[cfg(test)]
mod teardown_tests {
    use super::*;
    use std::future::pending;
    use std::sync::atomic::AtomicBool;

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
            let mut task = tokio::spawn(async move {
                let _probe = DropProbe(task_dropped_by_task);
                pending::<()>().await;
            });

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
