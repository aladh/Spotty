use super::*;
use std::future::pending;
use std::sync::atomic::AtomicBool;
use std::sync::Arc;

struct DropProbe(Arc<AtomicBool>);

impl Drop for DropProbe {
    fn drop(&mut self) {
        self.0.store(true, Ordering::SeqCst);
    }
}

#[test]
fn definitive_credential_rejection_is_terminal_but_transport_failure_retries() {
    for reason in [
        "Login failed with reason: Bad credentials",
        "Login failed with reason: Could not validate credentials",
    ] {
        let error = librespot_core::Error::permission_denied(std::io::Error::other(reason));
        assert!(is_definitive_credential_rejection(&error));
        assert_eq!(
            classify_initialization_error(&error),
            InitializationFailure::CredentialsRejected
        );
    }

    for (kind, reason) in [
        (
            librespot_core::error::ErrorKind::PermissionDenied,
            "Login failed with reason: Try another access point",
        ),
        (
            librespot_core::error::ErrorKind::PermissionDenied,
            "Login failed with reason: Premium account required",
        ),
        (
            librespot_core::error::ErrorKind::PermissionDenied,
            "Login failed with reason: Travel restriction",
        ),
        (
            librespot_core::error::ErrorKind::PermissionDenied,
            "permission denied for an unrelated operation",
        ),
        (
            librespot_core::error::ErrorKind::Unavailable,
            "transport returned no data",
        ),
        (
            librespot_core::error::ErrorKind::Unavailable,
            "Login failed with reason: Bad credentials",
        ),
    ] {
        let error = librespot_core::Error::new(kind, std::io::Error::other(reason));
        assert!(!is_definitive_credential_rejection(&error));
        assert_eq!(
            classify_initialization_error(&error),
            InitializationFailure::Transient
        );
    }
}

#[test]
fn async_reconnect_drains_cancelled_tasks_before_an_injected_build_failure() {
    let _guard = lock_lifecycle_test_globals();
    let task_dropped = Arc::new(AtomicBool::new(false));
    let build_started = Arc::new(AtomicBool::new(false));

    block_on_export(async {
        let (started_tx, started_rx) = tokio::sync::oneshot::channel();
        let task_probe_dropped = Arc::clone(&task_dropped);
        let task = tokio::spawn(async move {
            let _probe = DropProbe(task_probe_dropped);
            started_tx
                .send(())
                .expect("the cleanup test must observe the task after it starts");
            pending::<()>().await;
        });
        started_rx.await.expect("owned task started");

        let cleanup_task_dropped = Arc::clone(&task_dropped);
        let build_started = Arc::clone(&build_started);
        let outcome = run_reconnect_unit_async(
            4,
            || 4,
            || false,
            || async move {
                task.abort();
                let _ = task.await;
                assert!(
                    cleanup_task_dropped.load(Ordering::SeqCst),
                    "cleanup must await the cancelled task before building"
                );
            },
            async move {
                build_started.store(true, Ordering::SeqCst);
                Err::<(), _>("injected constructor failure")
            },
        )
        .await;

        assert!(matches!(
            outcome,
            ReconnectUnitOutcome::Ran(Err("injected constructor failure"))
        ));
    })
    .expect("lifecycle test");

    assert!(task_dropped.load(Ordering::SeqCst));
    assert!(build_started.load(Ordering::SeqCst));
}

#[test]
fn async_reconnect_does_not_poll_cleanup_or_build_after_generation_replacement() {
    let _guard = lock_lifecycle_test_globals();
    let cleanup_started = Arc::new(AtomicBool::new(false));
    let build_started = Arc::new(AtomicBool::new(false));

    block_on_export(async {
        let cleanup_started = Arc::clone(&cleanup_started);
        let build_started = Arc::clone(&build_started);
        let outcome = run_reconnect_unit_async(
            4,
            || 5,
            || false,
            || async move {
                cleanup_started.store(true, Ordering::SeqCst);
            },
            async move {
                build_started.store(true, Ordering::SeqCst);
                panic!("stale reconnect must not build");
            },
        )
        .await;

        assert!(matches!(outcome, ReconnectUnitOutcome::Abandoned));
    })
    .expect("lifecycle test");

    assert!(!cleanup_started.load(Ordering::SeqCst));
    assert!(!build_started.load(Ordering::SeqCst));
}

#[test]
fn teardown_engine_resources_awaits_every_owned_task_before_returning() {
    let _guard = lock_lifecycle_test_globals();
    let task_dropped = Arc::new(AtomicBool::new(false));

    block_on_export(async {
        let (started_tx, started_rx) = tokio::sync::oneshot::channel();
        let task_probe_dropped = Arc::clone(&task_dropped);
        let task = tokio::spawn(async move {
            let _probe = DropProbe(task_probe_dropped);
            started_tx
                .send(())
                .expect("the teardown test must observe the task after it starts");
            pending::<()>().await;
        });
        started_rx.await.expect("owned task started");

        with_engine(|engine| engine.tasks = Some(vec![task]));

        with_lifecycle_lock(async {
            let _store = enter_store_section();
            teardown_engine_resources("retained lifecycle test").await;
        })
        .await;
    })
    .expect("lifecycle test");

    assert!(
        task_dropped.load(Ordering::SeqCst),
        "teardown must await an aborted task before returning"
    );
    assert!(
        with_engine(|engine| engine.tasks.is_none()),
        "teardown must leave the generation's task registry empty"
    );
}
