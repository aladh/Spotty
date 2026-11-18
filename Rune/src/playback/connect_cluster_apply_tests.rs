use super::*;
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Barrier};
use std::thread;

const BOOTSTRAP_DEVICE: &str = "bootstrap-old";
const PUSH_DEVICE: &str = "push-new";

fn lock_globals() -> std::sync::MutexGuard<'static, ()> {
    lock_lifecycle_test_globals()
}

fn cluster_named(active_device_id: &str) -> Cluster {
    let mut cluster = Cluster::new();
    cluster.active_device_id = active_device_id.to_string();
    cluster
}

fn begin_generation(generation: u64) {
    reset_cluster_apply_test_state();
    set_session_generation_for_test(generation);
}

fn last_applied_device() -> Option<String> {
    applied_cluster_ids().last().cloned()
}

/// Replica of a per-generation "push seen" flag checked before apply. Bootstrap can pass
/// that check, wait, and still apply after a newer push has already become last writer.
fn offer_with_atomic_flag(
    origin: ClusterOrigin,
    cluster: Cluster,
    pushed: &AtomicBool,
    after_decide: impl FnOnce(),
    applied: &Mutex<Vec<String>>,
) {
    if origin == ClusterOrigin::BootstrapFetch && pushed.load(Ordering::SeqCst) {
        after_decide();
        return;
    }
    after_decide();
    if origin == ClusterOrigin::PushedUpdate {
        pushed.store(true, Ordering::SeqCst);
    }
    applied
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .push(cluster.active_device_id);
}

fn inversion_schedule(
    offer: impl Fn(ClusterOrigin, Cluster, Box<dyn FnOnce() + Send>) + Send + Sync + Copy,
) -> Vec<String> {
    let bootstrap_decided = Arc::new(Barrier::new(2));
    let push_decided = Arc::new(Barrier::new(2));

    thread::scope(|scope| {
        scope.spawn(|| {
            let bootstrap_decided = Arc::clone(&bootstrap_decided);
            let push_decided = Arc::clone(&push_decided);
            offer(
                ClusterOrigin::BootstrapFetch,
                cluster_named(BOOTSTRAP_DEVICE),
                Box::new(move || {
                    bootstrap_decided.wait();
                    push_decided.wait();
                }),
            );
        });
        scope.spawn(|| {
            bootstrap_decided.wait();
            let push_decided = Arc::clone(&push_decided);
            offer(
                ClusterOrigin::PushedUpdate,
                cluster_named(PUSH_DEVICE),
                Box::new(move || {
                    push_decided.wait();
                }),
            );
        });
    });

    applied_cluster_ids()
}

#[test]
fn a_push_discards_a_bootstrap_that_has_not_applied() {
    assert_eq!(
        cluster_offer_decision(ClusterOrigin::BootstrapFetch, 4, 4, true),
        ClusterOfferDecision::Discard
    );
}

#[test]
fn a_bootstrap_enqueues_when_no_push_has_been_seen() {
    assert_eq!(
        cluster_offer_decision(ClusterOrigin::BootstrapFetch, 4, 4, false),
        ClusterOfferDecision::Enqueue { mark_pushed: false }
    );
}

#[test]
fn a_push_always_enqueues_for_the_current_generation() {
    assert_eq!(
        cluster_offer_decision(ClusterOrigin::PushedUpdate, 4, 4, false),
        ClusterOfferDecision::Enqueue { mark_pushed: true }
    );
    assert_eq!(
        cluster_offer_decision(ClusterOrigin::PushedUpdate, 4, 4, true),
        ClusterOfferDecision::Enqueue { mark_pushed: true }
    );
}

#[test]
fn a_stale_generation_is_discarded_before_enqueue() {
    assert_eq!(
        cluster_offer_decision(ClusterOrigin::BootstrapFetch, 3, 4, false),
        ClusterOfferDecision::Discard
    );
    assert_eq!(
        cluster_offer_decision(ClusterOrigin::PushedUpdate, 3, 4, false),
        ClusterOfferDecision::Discard
    );
}

#[test]
fn pushed_before_bootstrap_discards_the_bootstrap() {
    let _guard = lock_globals();
    begin_generation(4);

    offer_cluster(ClusterOrigin::PushedUpdate, 4, cluster_named(PUSH_DEVICE));
    offer_cluster(
        ClusterOrigin::BootstrapFetch,
        4,
        cluster_named(BOOTSTRAP_DEVICE),
    );

    assert_eq!(applied_cluster_ids(), vec![PUSH_DEVICE.to_string()]);
    assert_eq!(last_applied_device().as_deref(), Some(PUSH_DEVICE));
}

#[test]
fn bootstrap_before_push_leaves_the_push_as_last_writer() {
    let _guard = lock_globals();
    begin_generation(4);

    offer_cluster(
        ClusterOrigin::BootstrapFetch,
        4,
        cluster_named(BOOTSTRAP_DEVICE),
    );
    offer_cluster(ClusterOrigin::PushedUpdate, 4, cluster_named(PUSH_DEVICE));

    assert_eq!(
        applied_cluster_ids(),
        vec![BOOTSTRAP_DEVICE.to_string(), PUSH_DEVICE.to_string()]
    );
    assert_eq!(last_applied_device().as_deref(), Some(PUSH_DEVICE));
}

#[test]
fn a_mere_atomic_flag_loses_when_bootstrap_decides_before_apply() {
    let pushed = AtomicBool::new(false);
    let applied = Mutex::new(Vec::new());
    let bootstrap_decided = Arc::new(Barrier::new(2));
    let push_applied = Arc::new(Barrier::new(2));

    thread::scope(|scope| {
        scope.spawn(|| {
            let bootstrap_decided = Arc::clone(&bootstrap_decided);
            let push_applied = Arc::clone(&push_applied);
            offer_with_atomic_flag(
                ClusterOrigin::BootstrapFetch,
                cluster_named(BOOTSTRAP_DEVICE),
                &pushed,
                || {
                    bootstrap_decided.wait();
                    push_applied.wait();
                },
                &applied,
            );
        });
        scope.spawn(|| {
            bootstrap_decided.wait();
            offer_with_atomic_flag(
                ClusterOrigin::PushedUpdate,
                cluster_named(PUSH_DEVICE),
                &pushed,
                || {},
                &applied,
            );
            push_applied.wait();
        });
    });

    assert_eq!(
        applied.lock().unwrap_or_else(|e| e.into_inner()).clone(),
        vec![PUSH_DEVICE.to_string(), BOOTSTRAP_DEVICE.to_string()],
        "a flag checked before apply lets the stale bootstrap become last writer"
    );
}

#[test]
fn decide_then_apply_interleaving_keeps_the_push_as_last_writer() {
    let _guard = lock_globals();
    begin_generation(4);

    let applied = inversion_schedule(|origin, cluster, after_decide| {
        offer_cluster_after_decide(origin, 4, cluster, after_decide);
    });

    assert_eq!(applied, vec![PUSH_DEVICE.to_string()]);
    assert_eq!(last_applied_device().as_deref(), Some(PUSH_DEVICE));
}

#[test]
fn a_stale_generation_enqueued_before_teardown_does_not_apply() {
    let _guard = lock_globals();
    begin_generation(4);

    let bootstrap_decided = Arc::new(Barrier::new(2));
    let generation_moved = Arc::new(Barrier::new(2));

    thread::scope(|scope| {
        scope.spawn(|| {
            let bootstrap_decided = Arc::clone(&bootstrap_decided);
            let generation_moved = Arc::clone(&generation_moved);
            offer_cluster_after_decide(
                ClusterOrigin::BootstrapFetch,
                4,
                cluster_named(BOOTSTRAP_DEVICE),
                move || {
                    bootstrap_decided.wait();
                    generation_moved.wait();
                },
            );
        });
        scope.spawn(|| {
            bootstrap_decided.wait();
            set_session_generation_for_test(5);
            generation_moved.wait();
        });
    });

    assert!(applied_cluster_ids().is_empty());
}

#[test]
fn a_superseded_offer_never_enqueues() {
    let _guard = lock_globals();
    begin_generation(5);

    offer_cluster(ClusterOrigin::PushedUpdate, 4, cluster_named(PUSH_DEVICE));
    offer_cluster(
        ClusterOrigin::BootstrapFetch,
        4,
        cluster_named(BOOTSTRAP_DEVICE),
    );

    assert!(applied_cluster_ids().is_empty());
}

#[test]
fn cleanup_drops_a_pending_bootstrap_instead_of_publishing_it() {
    let _guard = lock_globals();
    begin_generation(4);

    let bootstrap_decided = Arc::new(Barrier::new(2));
    let cleanup_done = Arc::new(Barrier::new(2));

    thread::scope(|scope| {
        scope.spawn(|| {
            let bootstrap_decided = Arc::clone(&bootstrap_decided);
            let cleanup_done = Arc::clone(&cleanup_done);
            offer_cluster_after_decide(
                ClusterOrigin::BootstrapFetch,
                4,
                cluster_named(BOOTSTRAP_DEVICE),
                move || {
                    bootstrap_decided.wait();
                    cleanup_done.wait();
                },
            );
        });
        scope.spawn(|| {
            bootstrap_decided.wait();
            set_session_generation_for_test(5);
            discard_retained_cluster_offers();
            cleanup_done.wait();
        });
    });

    assert!(applied_cluster_ids().is_empty());
}

#[test]
fn a_new_generation_can_bootstrap_after_a_prior_generation_push() {
    let _guard = lock_globals();
    begin_generation(4);

    offer_cluster(ClusterOrigin::PushedUpdate, 4, cluster_named(PUSH_DEVICE));
    assert_eq!(applied_cluster_ids(), vec![PUSH_DEVICE.to_string()]);

    set_session_generation_for_test(5);

    offer_cluster(
        ClusterOrigin::BootstrapFetch,
        5,
        cluster_named(BOOTSTRAP_DEVICE),
    );

    assert_eq!(
        applied_cluster_ids(),
        vec![PUSH_DEVICE.to_string(), BOOTSTRAP_DEVICE.to_string()]
    );
    assert_eq!(last_applied_device().as_deref(), Some(BOOTSTRAP_DEVICE));
}

#[test]
fn a_prior_generation_push_does_not_apply_after_replacement() {
    let _guard = lock_globals();
    begin_generation(4);

    let push_decided = Arc::new(Barrier::new(2));
    let replacement_done = Arc::new(Barrier::new(2));

    thread::scope(|scope| {
        scope.spawn(|| {
            let push_decided = Arc::clone(&push_decided);
            let replacement_done = Arc::clone(&replacement_done);
            offer_cluster_after_decide(
                ClusterOrigin::PushedUpdate,
                4,
                cluster_named(PUSH_DEVICE),
                move || {
                    push_decided.wait();
                    replacement_done.wait();
                },
            );
        });
        scope.spawn(|| {
            push_decided.wait();
            set_session_generation_for_test(5);
            offer_cluster(
                ClusterOrigin::BootstrapFetch,
                5,
                cluster_named(BOOTSTRAP_DEVICE),
            );
            replacement_done.wait();
        });
    });

    assert_eq!(applied_cluster_ids(), vec![BOOTSTRAP_DEVICE.to_string()]);
    assert_eq!(last_applied_device().as_deref(), Some(BOOTSTRAP_DEVICE));
}

#[test]
fn pop_then_generation_advance_does_not_apply() {
    let _guard = lock_globals();
    begin_generation(4);

    let popped = Arc::new(Barrier::new(2));
    let torn_down = Arc::new(Barrier::new(2));

    thread::scope(|scope| {
        scope.spawn(|| {
            let popped = Arc::clone(&popped);
            let torn_down = Arc::clone(&torn_down);
            offer_cluster_with_hooks(
                ClusterOrigin::BootstrapFetch,
                4,
                cluster_named(BOOTSTRAP_DEVICE),
                || {},
                Some(Arc::new(move || {
                    popped.wait();
                    torn_down.wait();
                })),
            );
        });
        scope.spawn(|| {
            popped.wait();
            invalidate_cluster_generation();
            torn_down.wait();
        });
    });

    assert!(applied_cluster_ids().is_empty());
}

#[test]
fn a_replacement_generation_still_drains_after_invalidation_wait() {
    let _guard = lock_globals();
    begin_generation(4);

    let popped = Arc::new(Barrier::new(3));
    let offered = Arc::new(Barrier::new(2));
    let torn_down = Arc::new(Barrier::new(2));

    thread::scope(|scope| {
        scope.spawn(|| {
            let popped = Arc::clone(&popped);
            let torn_down = Arc::clone(&torn_down);
            offer_cluster_with_hooks(
                ClusterOrigin::BootstrapFetch,
                4,
                cluster_named(BOOTSTRAP_DEVICE),
                || {},
                Some(Arc::new(move || {
                    popped.wait();
                    torn_down.wait();
                })),
            );
        });
        scope.spawn(|| {
            popped.wait();
            offer_cluster(ClusterOrigin::PushedUpdate, 4, cluster_named(PUSH_DEVICE));
            offered.wait();
        });
        scope.spawn(|| {
            popped.wait();
            wait_for_cluster_mapping_idle();
            offered.wait();
            invalidate_cluster_generation();
            torn_down.wait();
        });
    });

    assert!(applied_cluster_ids().is_empty());

    offer_cluster(
        ClusterOrigin::BootstrapFetch,
        SESSION_GENERATION.load(Ordering::SeqCst),
        cluster_named(BOOTSTRAP_DEVICE),
    );
    assert_eq!(applied_cluster_ids(), vec![BOOTSTRAP_DEVICE.to_string()]);
    assert_eq!(last_applied_device().as_deref(), Some(BOOTSTRAP_DEVICE));
}

#[test]
fn a_panicking_claimant_does_not_strand_the_next_offer() {
    let _guard = lock_globals();
    begin_generation(4);

    offer_cluster_with_hooks(
        ClusterOrigin::BootstrapFetch,
        4,
        cluster_named(BOOTSTRAP_DEVICE),
        || {},
        Some(Arc::new(|| panic!("test claimant unwind"))),
    );
    assert!(applied_cluster_ids().is_empty());

    offer_cluster(ClusterOrigin::PushedUpdate, 4, cluster_named(PUSH_DEVICE));
    assert_eq!(applied_cluster_ids(), vec![PUSH_DEVICE.to_string()]);
    assert_eq!(last_applied_device().as_deref(), Some(PUSH_DEVICE));
}

#[test]
fn a_queued_offer_drains_after_the_claimant_unwinds() {
    let _guard = lock_globals();
    begin_generation(4);

    let popped = Arc::new(Barrier::new(2));
    let queued = Arc::new(Barrier::new(2));

    thread::scope(|scope| {
        scope.spawn(|| {
            let popped = Arc::clone(&popped);
            let queued = Arc::clone(&queued);
            offer_cluster_with_hooks(
                ClusterOrigin::BootstrapFetch,
                4,
                cluster_named(BOOTSTRAP_DEVICE),
                || {},
                Some(Arc::new(move || {
                    popped.wait();
                    queued.wait();
                    panic!("test claimant unwind");
                })),
            );
        });
        scope.spawn(|| {
            popped.wait();
            offer_cluster(ClusterOrigin::PushedUpdate, 4, cluster_named(PUSH_DEVICE));
            queued.wait();
        });
    });

    assert_eq!(applied_cluster_ids(), vec![PUSH_DEVICE.to_string()]);
    assert_eq!(last_applied_device().as_deref(), Some(PUSH_DEVICE));
}
