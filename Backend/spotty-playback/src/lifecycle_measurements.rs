//! Credential-free measurements of production lifecycle seams, never a second engine.
use super::*;
use serde_json::json;
use std::sync::atomic::AtomicBool;

fn silent_detection_samples() -> Vec<serde_json::Value> {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_time()
        .start_paused(true)
        .build()
        .unwrap();
    let mut detection = Vec::new();
    for phase_ms in [0, 17_000, 59_500] {
        let elapsed = runtime.block_on(async {
            let invalid = Arc::new(AtomicBool::new(false));
            let observed = Arc::clone(&invalid);
            let watcher = run_session_health_check(move || {
                health_check_should_recover(observed.load(Ordering::SeqCst), true, false, false)
            });
            tokio::pin!(watcher);
            // Poll the shared watcher through its first sleep registration before advancing
            // time. Yielding to a spawned task would not guarantee it had registered yet.
            assert!(futures_util::poll!(&mut watcher).is_pending());
            tokio::time::advance(Duration::from_millis(phase_ms)).await;
            invalid.store(true, Ordering::SeqCst);
            let started = tokio::time::Instant::now();
            watcher.await;
            started.elapsed().as_millis() as u64
        });
        assert_eq!(elapsed, 60_000 - phase_ms);
        detection.push(
            json!({"fault": "silent-invalid-session", "phaseMilliseconds": phase_ms,
            "detectionMilliseconds": elapsed, "clock": "paused Tokio policy clock"}),
        );
    }

    detection
}

#[test]
fn silent_session_fault_detection_uses_production_cadence() {
    let _samples = silent_detection_samples();
}

#[test]
#[ignore = "wall-clock lifecycle measurement; run explicitly with --ignored"]
fn named_lifecycle_fault_measurements() {
    let _guard = lock_lifecycle_test_globals();
    let detection = silent_detection_samples();
    let mut wake = Vec::new();
    let mut drain = Vec::new();
    // The test owns no Session, credentials, Spirc or renderer. It measures serialized
    // orchestration with explicitly injected cleanup/build costs, not Spotify connect time.
    block_on_export(async {
        for _ in 0..30 {
            let mut lease = RecoveryLease::claim().expect("uncontended recovery owner");
            lease.begin_attempt();
            assert!(
                RecoveryLease::claim().is_none(),
                "overlapping wake must join"
            );
            let outcome = run_reconnect_unit_async(
                4,
                || 4,
                || false,
                || async { tokio::time::sleep(Duration::from_millis(5)).await },
                async {
                    tokio::time::sleep(Duration::from_millis(20)).await;
                    Ok::<(), ()>(())
                },
            )
            .await;
            assert!(matches!(outcome, ReconnectUnitOutcome::Ran(Ok(()))));
            let report = lease.finish(RecoveryOutcome::Ready);
            assert_eq!(report.attempts, 1);
            wake.push(report.elapsed.as_secs_f64() * 1_000.0);

            let mut tasks = Vec::new();
            let settled = Arc::new(std::sync::atomic::AtomicUsize::new(0));
            for _ in 0..5 {
                let settled = Arc::clone(&settled);
                let (started_tx, started_rx) = tokio::sync::oneshot::channel();
                tasks.push(tokio::spawn(async move {
                    struct Probe(Arc<std::sync::atomic::AtomicUsize>);
                    impl Drop for Probe {
                        fn drop(&mut self) {
                            self.0.fetch_add(1, Ordering::SeqCst);
                        }
                    }
                    let _probe = Probe(settled);
                    started_tx.send(()).unwrap();
                    std::future::pending::<()>().await;
                }));
                started_rx.await.unwrap();
            }
            let started = std::time::Instant::now();
            with_lifecycle_lock(async {
                let _store = enter_store_section();
                *ENGINE_TASKS.lock().unwrap() = Some(tasks);
                teardown_engine_resources("five parked child fault").await;
            })
            .await;
            drain.push(started.elapsed().as_secs_f64() * 1_000.0);
            assert_eq!(settled.load(Ordering::SeqCst), 5);
            assert!(ENGINE_TASKS.lock().unwrap().is_none());
        }
    })
    .unwrap();
    if let Ok(path) = std::env::var("SPOTTY_LIFECYCLE_REPORT") {
        let report = json!({"version": 1, "silentDetection": detection,
            "wake": {"fault": "overlapping-wake; injected cleanup 5ms + build 20ms",
                "clock": "wall monotonic", "milliseconds": wake},
            "shutdown": {"fault": "five parked cancellable engine children; no Session/Spirc",
                "clock": "wall monotonic", "milliseconds": drain},
            "limitations": "No live network, AP construction, audio, dealer close or Swift drain measured here"});
        std::fs::write(path, serde_json::to_vec_pretty(&report).unwrap()).unwrap();
    }
}
