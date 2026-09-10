use super::*;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64};
use std::sync::Arc;
use std::time::Duration;

fn lock_globals() -> std::sync::MutexGuard<'static, ()> {
    lock_lifecycle_test_globals()
}

#[test]
fn reconnect_generation_is_captured_at_trigger_not_task_start() {
    let _guard = lock_globals();
    cancel_recovery();

    let intent = RecoveryIntent {
        was_playing: false,
        was_active: false,
    };
    let at_trigger = 2;
    let start = start_reconnect_loop(intent, at_trigger).expect("claimed reconnect");
    assert_eq!(start.recovering_generation, at_trigger);
    assert_eq!(start.intent, intent);

    // A rebuild landed before the task ran. Loading the counter at task start
    // would adopt 3 and proceed to tear that session down.
    let at_task_start = 3;
    assert!(
        !reconnect_may_proceed(start.recovering_generation, at_task_start, false),
        "a rebuild between trigger and task start must abandon before cleanup"
    );
    assert!(
        reconnect_may_proceed(at_task_start, at_task_start, false),
        "capturing at task start would have adopted the newer generation"
    );

    cancel_recovery();
}

#[test]
fn two_lifecycle_ops_never_enter_the_store_section_together() {
    let _guard = lock_globals();
    reset_store_section_stats();

    block_on_export(async {
        let ready = Arc::new(tokio::sync::Barrier::new(2));

        let op = |ready: Arc<tokio::sync::Barrier>| async move {
            ready.wait().await;
            with_lifecycle_lock(async {
                let _section = enter_store_section();
                // Yield so the sibling task can contend for the lock while this
                // section is still open. `RUNTIME` is multi-thread.
                tokio::time::sleep(Duration::from_millis(80)).await;
            })
            .await;
        };

        let first = tokio::spawn(op(ready.clone()));
        let second = tokio::spawn(op(ready));
        first.await.expect("first lifecycle op");
        second.await.expect("second lifecycle op");
    })
    .expect("lifecycle test");

    assert_eq!(store_section_entries(), 2);
    assert!(
        !store_section_overlapped(),
        "two serialized ops entered the store/commit section at the same time"
    );
}

#[test]
fn queued_stale_reconnect_revalidates_and_skips_cleanup_and_build() {
    let _guard = lock_globals();
    reset_store_section_stats();

    let cleaned = Arc::new(AtomicU32::new(0));
    let built = Arc::new(AtomicU32::new(0));
    let current = Arc::new(AtomicU64::new(2));

    block_on_export(async {
        let queued = Arc::new(tokio::sync::Barrier::new(2));

        let newer_session = {
            let queued = queued.clone();
            let current = current.clone();
            async move {
                let _lock = acquire_lifecycle().await;
                queued.wait().await;
                current.store(3, Ordering::SeqCst);
                tokio::time::sleep(Duration::from_millis(40)).await;
            }
        };

        let stale_reconnect = {
            let queued = queued.clone();
            let current = current.clone();
            let cleaned = cleaned.clone();
            let built = built.clone();
            async move {
                queued.wait().await;
                run_reconnect_unit(
                    2,
                    || current.load(Ordering::SeqCst),
                    || false,
                    || {
                        let _section = enter_store_section();
                        cleaned.fetch_add(1, Ordering::SeqCst);
                    },
                    async {
                        let _section = enter_store_section();
                        built.fetch_add(1, Ordering::SeqCst);
                    },
                )
                .await
            }
        };

        let holder = tokio::spawn(newer_session);
        let waiter = tokio::spawn(stale_reconnect);
        holder.await.expect("newer session holder");
        let outcome = waiter.await.expect("stale reconnect");
        assert!(matches!(outcome, ReconnectUnitOutcome::Abandoned));
    })
    .expect("lifecycle test");

    assert_eq!(cleaned.load(Ordering::SeqCst), 0);
    assert_eq!(built.load(Ordering::SeqCst), 0);
    assert_eq!(store_section_entries(), 0);
}

#[test]
fn exported_init_recheck_prevents_a_second_build_after_waiting() {
    let _guard = lock_globals();
    let session_present = Arc::new(AtomicBool::new(false));
    let built = Arc::new(AtomicU32::new(0));

    block_on_export(async {
        let waiter_ready = Arc::new(tokio::sync::Barrier::new(2));

        let first_build = {
            let waiter_ready = waiter_ready.clone();
            let session_present = session_present.clone();
            async move {
                let _lock = acquire_lifecycle().await;
                waiter_ready.wait().await;
                session_present.store(true, Ordering::SeqCst);
                tokio::time::sleep(Duration::from_millis(40)).await;
            }
        };

        let second_init = {
            let waiter_ready = waiter_ready.clone();
            let session_present = session_present.clone();
            let built = built.clone();
            async move {
                waiter_ready.wait().await;
                run_serialized_init(|| session_present.load(Ordering::SeqCst), async {
                    built.fetch_add(1, Ordering::SeqCst);
                })
                .await
            }
        };

        let holder = tokio::spawn(first_build);
        let waiter = tokio::spawn(second_init);
        holder.await.expect("first build holder");
        let outcome = waiter.await.expect("second init");
        assert!(matches!(outcome, SerializedInitOutcome::AlreadyInitialized));
    })
    .expect("lifecycle test");

    assert_eq!(built.load(Ordering::SeqCst), 0);
}

#[test]
fn exported_init_builds_when_the_recheck_still_sees_no_session() {
    let _guard = lock_globals();
    block_on_export(async {
        let outcome = run_serialized_init(|| false, async { 7u8 }).await;
        match outcome {
            SerializedInitOutcome::Built(value) => assert_eq!(value, 7),
            SerializedInitOutcome::AlreadyInitialized => {
                panic!("empty session must still build")
            }
        }
    })
    .expect("lifecycle test");
}

#[test]
fn reconnect_unit_runs_cleanup_and_build_when_generation_still_matches() {
    let _guard = lock_globals();
    let cleaned = Arc::new(AtomicBool::new(false));
    let built = Arc::new(AtomicBool::new(false));

    block_on_export(async {
        let outcome = run_reconnect_unit(
            4,
            || 4,
            || false,
            || cleaned.store(true, Ordering::SeqCst),
            async {
                built.store(true, Ordering::SeqCst);
                Ok::<(), String>(())
            },
        )
        .await;
        assert!(matches!(outcome, ReconnectUnitOutcome::Ran(Ok(()))));
    })
    .expect("lifecycle test");

    assert!(cleaned.load(Ordering::SeqCst));
    assert!(built.load(Ordering::SeqCst));
}

#[test]
fn reconnect_unit_abandons_during_teardown_without_cleanup() {
    let _guard = lock_globals();
    let cleaned = Arc::new(AtomicBool::new(false));

    block_on_export(async {
        let outcome = run_reconnect_unit(
            4,
            || 4,
            || true,
            || cleaned.store(true, Ordering::SeqCst),
            async {
                panic!("teardown must not build");
            },
        )
        .await;
        assert!(matches!(outcome, ReconnectUnitOutcome::Abandoned));
    })
    .expect("lifecycle test");

    assert!(!cleaned.load(Ordering::SeqCst));
}

#[test]
fn overlapping_recovery_triggers_share_one_owner_and_stale_finish_cannot_clear_replacement() {
    let _guard = lock_globals();
    cancel_recovery();
    let old = RecoveryLease::claim().expect("first trigger");
    for _ in 0..4 {
        assert!(
            RecoveryLease::claim().is_none(),
            "wake, stream, command and health triggers coalesce"
        );
    }
    cancel_recovery();
    assert!(old.is_cancelled());
    let replacement = RecoveryLease::claim().expect("wake after sleep");
    drop(old);
    assert!(
        recovery_is_active(),
        "old completion must not clear new owner"
    );
    assert!(!replacement.is_cancelled());
    drop(replacement);
    assert!(!recovery_is_active());
}

#[test]
fn cancelled_recovery_backoff_settles_without_waiting_for_outage_delay() {
    let _guard = lock_globals();
    cancel_recovery();
    block_on_export(async {
        let mut lease = RecoveryLease::claim().expect("recovery");
        let started = std::time::Instant::now();
        let task = tokio::spawn(async move { lease.wait(Duration::from_secs(30)).await });
        tokio::task::yield_now().await;
        cancel_recovery();
        assert!(!tokio::time::timeout(Duration::from_secs(1), task)
            .await
            .expect("bounded cancellation")
            .expect("settled task"));
        eprintln!(
            "recovery backoff cancellation settled in {:?} (budget 1s)",
            started.elapsed()
        );
    })
    .expect("runtime");
    assert!(!recovery_is_active());
}

#[test]
fn outage_retry_schedule_remains_bounded_without_a_terminal_attempt() {
    assert_eq!(
        (0..6)
            .map(recovery_delay)
            .map(|d| d.as_secs())
            .collect::<Vec<_>>(),
        vec![0, 2, 5, 10, 30, 30]
    );
    assert_eq!(recovery_delay(u32::MAX), Duration::from_secs(30));
}

#[test]
fn retired_recovery_waiting_for_lifecycle_cannot_clean_or_build() {
    let _guard = lock_globals();
    cancel_recovery();
    block_on_export(async {
        let lease = RecoveryLease::claim().expect("recovery");
        let lock = acquire_lifecycle().await;
        let task = tokio::spawn(async move {
            run_reconnect_unit_async(
                4,
                || 4,
                || lease.is_cancelled(),
                || async { panic!("retired run must not clean") },
                async { panic!("retired run must not build") },
            )
            .await
        });
        tokio::task::yield_now().await;
        cancel_recovery();
        drop(lock);
        assert!(matches!(
            task.await.expect("settled"),
            ReconnectUnitOutcome::Abandoned
        ));
    })
    .expect("runtime");
}

#[test]
fn retired_recovery_does_not_begin_session_construction() {
    let _guard = lock_globals();
    cancel_recovery();
    let lease = RecoveryLease::claim().expect("recovery");
    cancel_recovery();
    let before = SESSION_GENERATION.load(Ordering::SeqCst);
    let result =
        block_on_export(build_player_owned(None, false, false, Some(&lease))).expect("runtime");
    assert_eq!(result, Err(InitializationFailure::Transient));
    assert_eq!(SESSION_GENERATION.load(Ordering::SeqCst), before);
}

#[test]
fn recovery_attempt_does_not_require_a_registered_connection_callback() {
    let _guard = lock_globals();
    cancel_recovery();
    let old_callback = CONTROL_CALLBACKS.connection_state.lock().unwrap().take();
    let old_error = with_connection(|c| c.last_error.clone());
    let lease = RecoveryLease::claim().expect("recovery");
    let generation = SESSION_GENERATION.load(Ordering::SeqCst);
    assert!(publish_recovery_attempt(generation, &lease, 1));
    assert!(recovery_is_active());
    cancel_recovery();
    assert!(!publish_recovery_attempt(generation, &lease, 2));
    *CONTROL_CALLBACKS.connection_state.lock().unwrap() = old_callback;
    with_connection(|c| c.last_error = old_error);
}

#[test]
fn recovery_reports_named_terminal_outcomes_and_attempt_count() {
    let _guard = lock_globals();
    cancel_recovery();
    for outcome in [
        RecoveryOutcome::Ready,
        RecoveryOutcome::CredentialsRejected,
        RecoveryOutcome::Stopped,
    ] {
        let mut lease = RecoveryLease::claim().expect("recovery");
        assert_eq!(lease.begin_attempt(), 1);
        assert_eq!(lease.begin_attempt(), 2);
        let report = lease.finish(outcome);
        assert_eq!(report.outcome, outcome);
        assert_eq!(report.attempts, 2);
        assert!(!recovery_is_active());
    }
}
