use crate::*;
use std::collections::VecDeque;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::thread::ThreadId;

/// Who produced a cluster that wants to be mapped through [`apply_cluster`].
///
/// The HTTP bootstrap is a one-shot snapshot of whatever the service had when the PUT
/// returned. A dealer `ClusterUpdate` is a later observation of the same session. They share
/// one apply path, but they must not last-write-win: a slower bootstrap can otherwise overwrite a
/// newer push and receive a later `stamped_snapshot` revision, which Swift cannot reject.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ClusterOrigin {
    BootstrapFetch,
    PushedUpdate,
}

/// Whether an offered cluster may enter the per-generation apply queue.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ClusterOfferDecision {
    Discard,
    Enqueue { mark_pushed: bool },
}

/// Linearizes bootstrap vs push for one session generation, and mapping vs teardown.
///
/// A flag checked before `apply_cluster` is not enough: the bootstrap can observe "no push
/// yet", a push can apply, and the bootstrap can still apply afterwards. Decision and enqueue
/// share this mutex; [`apply_cluster`] runs only from the claimant drain, after the guard is
/// dropped, so Swift callbacks cannot re-enter this lock. Nested `offer_cluster` from a
/// callback only enqueues. The bootstrap task is not aborted when superseded; it re-checks
/// generation here and at apply time instead.
///
/// `applying` is the drain claim (empty-queue clear only). `mapping` is in-flight
/// [`apply_cluster`]. Invalidation waits on `mapping` only, before bumping
/// `SESSION_GENERATION`, so an already-started map finishes under its origin generation.
/// A popped item that has not begun mapping is not waited on: tests can inject teardown in
/// that gap, and [`begin_cluster_mapping`] re-checks generation so the item does not apply.
/// Waiting on `applying` would deadlock that schedule (drain claimed, hook waiting for
/// cleanup, cleanup waiting for drain).
///
/// Re-entry: `apply_cluster` delivers into Swift with no gate lock held. If that callback
/// invokes cleanup on this thread, [`invalidate_cluster_generation`] must not wait for
/// itself. Cleanup then bumps generation; remaining mapping steps re-check and stop.
/// A concurrent new offer only enqueues while the drain claim is held, so it is not
/// stranded: the claimant continues after mapping Drop, or teardown discards it after the
/// bump. The drain `applying` flag is cleared on empty-queue under the mutex, and on
/// unwind of the claimant only; an unconditional Drop clear races a concurrent enqueue.
struct ClusterApplyGate {
    pending: VecDeque<PendingCluster>,
    applying: bool,
    mapping: bool,
    mapping_thread: Option<ThreadId>,
    pushed_generation: Option<u64>,
}

struct PendingCluster {
    origin: ClusterOrigin,
    generation: u64,
    cluster: Cluster,
    #[cfg(test)]
    after_pop: Option<Arc<dyn Fn() + Send + Sync>>,
}

static CLUSTER_APPLY: Lazy<Mutex<ClusterApplyGate>> = Lazy::new(|| {
    Mutex::new(ClusterApplyGate {
        pending: VecDeque::new(),
        applying: false,
        mapping: false,
        mapping_thread: None,
        pushed_generation: None,
    })
});
static CLUSTER_APPLY_CV: Condvar = Condvar::new();

pub(crate) fn cluster_offer_decision(
    origin: ClusterOrigin,
    listener_generation: u64,
    current_generation: u64,
    pushed_in_this_generation: bool,
) -> ClusterOfferDecision {
    if !listener_may_act(listener_generation, current_generation) {
        return ClusterOfferDecision::Discard;
    }
    match origin {
        ClusterOrigin::PushedUpdate => ClusterOfferDecision::Enqueue { mark_pushed: true },
        ClusterOrigin::BootstrapFetch if pushed_in_this_generation => ClusterOfferDecision::Discard,
        ClusterOrigin::BootstrapFetch => ClusterOfferDecision::Enqueue { mark_pushed: false },
    }
}

fn lock_cluster_apply() -> std::sync::MutexGuard<'static, ClusterApplyGate> {
    CLUSTER_APPLY.lock().unwrap_or_else(|e| e.into_inner())
}

fn cluster_generation_current(generation: u64) -> bool {
    listener_may_act(generation, SESSION_GENERATION.load(Ordering::SeqCst))
}

fn wait_for_cluster_mapping_idle_locked(
    mut gate: std::sync::MutexGuard<'static, ClusterApplyGate>,
) -> std::sync::MutexGuard<'static, ClusterApplyGate> {
    let current = std::thread::current().id();
    while gate.mapping && gate.mapping_thread != Some(current) {
        gate = CLUSTER_APPLY_CV
            .wait(gate)
            .unwrap_or_else(|e| e.into_inner());
    }
    gate
}

/// Waits until no [`apply_cluster`] is running on another thread, then advances
/// `SESSION_GENERATION` and drops pending offers while still holding the gate lock.
///
/// `begin_cluster_mapping` uses that same lock, so it cannot start mapping under the
/// outgoing generation in the gap after idle and before the bump. Condvar wait releases
/// the lock; Swift delivery and `await` never hold it. Same-thread mapping (callback →
/// cleanup) does not wait for itself.
pub(crate) fn invalidate_cluster_generation() -> u64 {
    let mut gate = wait_for_cluster_mapping_idle_locked(lock_cluster_apply());
    let invalidated =
        with_generation_mutation(|| SESSION_GENERATION.fetch_add(1, Ordering::SeqCst) + 1);
    gate.pending.clear();
    gate.pushed_generation = None;
    invalidated
}

/// Wait-only helper for tests that need to observe idle without bumping.
#[cfg(test)]
pub(crate) fn wait_for_cluster_mapping_idle() {
    let _gate = wait_for_cluster_mapping_idle_locked(lock_cluster_apply());
}

struct ClusterMappingGuard;

impl Drop for ClusterMappingGuard {
    fn drop(&mut self) {
        let mut gate = lock_cluster_apply();
        gate.mapping = false;
        gate.mapping_thread = None;
        CLUSTER_APPLY_CV.notify_all();
    }
}

fn begin_cluster_mapping(item: &PendingCluster) -> Option<ClusterMappingGuard> {
    let mut gate = lock_cluster_apply();
    if !cluster_generation_current(item.generation) {
        return None;
    }
    if item.origin == ClusterOrigin::BootstrapFetch
        && gate.pushed_generation == Some(item.generation)
    {
        return None;
    }
    gate.mapping = true;
    gate.mapping_thread = Some(std::thread::current().id());
    Some(ClusterMappingGuard)
}

/// Drops not-yet-applied clusters so a replaced session cannot retain them after logout.
pub(crate) fn discard_retained_cluster_offers() {
    let mut gate = lock_cluster_apply();
    gate.pending.clear();
    gate.pushed_generation = None;
}

/// Offers a cluster for the shared [`apply_cluster`] mapping.
///
/// If a push for this generation is already queued or applied, the bootstrap is discarded. If
/// the bootstrap already won an apply, a later push still applies after it. Callers must not
/// hold this function's lock — there is none across `apply_cluster` or any `await`.
pub(crate) fn offer_cluster(origin: ClusterOrigin, generation: u64, cluster: Cluster) {
    let claimed = enqueue_cluster_offer_default(origin, generation, cluster);
    if claimed {
        drain_offered_clusters();
    }
}

/// `after_decide` runs after enqueue-or-discard and before this thread applies or returns.
/// Tests use it to force decide/apply interleaving. It must not wait on this drain completing
/// if it also offers another cluster from the same thread.
#[cfg(test)]
pub(crate) fn offer_cluster_after_decide(
    origin: ClusterOrigin,
    generation: u64,
    cluster: Cluster,
    after_decide: impl FnOnce(),
) {
    let claimed = enqueue_cluster_offer(origin, generation, cluster, None);
    after_decide();
    if claimed {
        drain_offered_clusters();
    }
}

/// `after_pop` runs after this item is popped and generation-checked, before mapping begins.
/// Tests use it to force pop/revalidate → teardown → apply.
#[cfg(test)]
pub(crate) fn offer_cluster_with_hooks(
    origin: ClusterOrigin,
    generation: u64,
    cluster: Cluster,
    after_decide: impl FnOnce(),
    after_pop: Option<Arc<dyn Fn() + Send + Sync>>,
) {
    let claimed = enqueue_cluster_offer(origin, generation, cluster, after_pop);
    after_decide();
    if claimed {
        drain_offered_clusters();
    }
}

fn enqueue_cluster_offer_default(origin: ClusterOrigin, generation: u64, cluster: Cluster) -> bool {
    #[cfg(test)]
    {
        enqueue_cluster_offer(origin, generation, cluster, None)
    }
    #[cfg(not(test))]
    enqueue_cluster_offer(origin, generation, cluster)
}

fn enqueue_cluster_offer(
    origin: ClusterOrigin,
    generation: u64,
    cluster: Cluster,
    #[cfg(test)] after_pop: Option<Arc<dyn Fn() + Send + Sync>>,
) -> bool {
    {
        let mut gate = lock_cluster_apply();
        let current_generation = SESSION_GENERATION.load(Ordering::SeqCst);
        let pushed_in_this_generation = gate.pushed_generation == Some(generation);
        match cluster_offer_decision(
            origin,
            generation,
            current_generation,
            pushed_in_this_generation,
        ) {
            ClusterOfferDecision::Discard => {
                debug!(
                    "Cluster offer discarded (origin={:?}, generation={}, current={})",
                    origin, generation, current_generation
                );
                false
            }
            ClusterOfferDecision::Enqueue { mark_pushed } => {
                if mark_pushed {
                    gate.pushed_generation = Some(generation);
                }
                gate.pending.push_back(PendingCluster {
                    origin,
                    generation,
                    cluster,
                    #[cfg(test)]
                    after_pop,
                });
                let claimed = !gate.applying;
                if claimed {
                    gate.applying = true;
                }
                claimed
            }
        }
    }
}

/// Clears `applying` on unexpected claimant unwind. Item panics are caught in
/// [`drain_pending_clusters`] so remaining work is not drained from Drop (a second
/// panic there would abort).
struct DrainClaim;

impl Drop for DrainClaim {
    fn drop(&mut self) {
        if !std::thread::panicking() {
            return;
        }
        let mut gate = lock_cluster_apply();
        gate.applying = false;
    }
}

fn drain_offered_clusters() {
    let _claim = DrainClaim;
    drain_pending_clusters();
}

fn drain_pending_clusters() {
    loop {
        let Some(item) = pop_next_cluster_to_apply() else {
            return;
        };
        let _ = catch_unwind(AssertUnwindSafe(|| apply_offered_cluster(item)));
    }
}

fn apply_offered_cluster(item: PendingCluster) {
    #[cfg(test)]
    if let Some(hook) = &item.after_pop {
        hook();
    }
    let Some(_mapping) = begin_cluster_mapping(&item) else {
        return;
    };
    #[cfg(test)]
    record_applied_cluster(&item.cluster);
    apply_cluster(item.generation, item.cluster);
}

fn pop_next_cluster_to_apply() -> Option<PendingCluster> {
    let mut gate = lock_cluster_apply();
    loop {
        let Some(item) = gate.pending.pop_front() else {
            gate.applying = false;
            return None;
        };
        if !cluster_generation_current(item.generation) {
            continue;
        }
        if item.origin == ClusterOrigin::BootstrapFetch
            && gate.pushed_generation == Some(item.generation)
        {
            continue;
        }
        return Some(item);
    }
}

#[cfg(test)]
static APPLIED_CLUSTER_IDS: Lazy<Mutex<Vec<String>>> = Lazy::new(|| Mutex::new(Vec::new()));

#[cfg(test)]
fn record_applied_cluster(cluster: &Cluster) {
    APPLIED_CLUSTER_IDS
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .push(cluster.active_device_id.clone());
}

#[cfg(test)]
pub(crate) fn reset_cluster_apply_test_state() {
    let mut gate = lock_cluster_apply();
    gate.pending.clear();
    gate.applying = false;
    gate.mapping = false;
    gate.mapping_thread = None;
    gate.pushed_generation = None;
    CLUSTER_APPLY_CV.notify_all();
    drop(gate);
    APPLIED_CLUSTER_IDS
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clear();
}

#[cfg(test)]
pub(crate) fn applied_cluster_ids() -> Vec<String> {
    APPLIED_CLUSTER_IDS
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
}

/// Publishes the current connection observation.
///
/// Presentation (session phase, local display name) is Swift-owned
/// (`ConnectionSnapshotProjection`). Reading the state and assigning the revision happen
/// together, so two concurrent publishers cannot end up with revisions that contradict
/// the order they read state in. Delivery is deliberately left outside: the C snapshot
/// callback re-enters Swift, which must never happen while a lock is held.
pub(crate) struct ConnectionStateNotification {
    callback: ConnectionSnapshotCallback,
    stamp: SnapshotStamp,
    state: ConnectionState,
}

/// Captures a connection callback for an explicit owner generation.
///
/// Event listeners release the generation mutation gate before entering Swift. Capturing the
/// state, callback, revision, and owner generation together keeps a delayed callback from being
/// relabeled as the replacement session.
pub(crate) fn capture_connection_state_notification(
    session_generation: u64,
) -> Option<ConnectionStateNotification> {
    let callback = registered_callback(&CONTROL_CALLBACKS.connection_state)?;
    let (stamp, state) = stamped_snapshot_for_generation(session_generation, |stamp| {
        (stamp, with_connection(|c| c.clone()))
    });
    Some(ConnectionStateNotification {
        callback,
        stamp,
        state,
    })
}

/// Captures the current connection observation while the revision helper also reads the current
/// generation. This is the normal publisher path; callers that already own a listener generation
/// use [`capture_connection_state_notification`] so a later replacement cannot relabel it.
fn capture_current_connection_state_notification() -> Option<ConnectionStateNotification> {
    let callback = registered_callback(&CONTROL_CALLBACKS.connection_state)?;
    let (stamp, state) = stamped_snapshot(|stamp| (stamp, with_connection(|c| c.clone())));
    Some(ConnectionStateNotification {
        callback,
        stamp,
        state,
    })
}

/// Delivers a captured connection callback without holding any Rust state lock.
pub(crate) fn deliver_connection_state_notification(notification: ConnectionStateNotification) {
    let ConnectionStateNotification {
        callback,
        stamp,
        state,
    } = notification;
    send_connection_snapshot(callback, stamp, &state);
}

pub(crate) fn notify_connection_state_change() {
    if let Some(notification) = capture_current_connection_state_notification() {
        deliver_connection_state_notification(notification);
    }
}

/// Marks the session as disconnected, records the reason, and notifies the UI.
pub(crate) fn mark_disconnected(reason: &str) {
    with_connection(|c| {
        c.session_connected = false;
        c.last_error = Some(reason.to_string());
    });
    notify_connection_state_change();
}

/// Sends cluster members to Swift, skipping an update that says nothing new.
///
/// Presentation (activity, empty-type fallback, unused Web API fields) is Swift-owned.
/// This sorts by id only so the protobuf map cannot look like a new list every tick.
pub(crate) fn notify_devices(
    devices: &std::collections::HashMap<String, librespot_protocol::connect::DeviceInfo>,
    active_device_id: &str,
) {
    let mut list: Vec<ProtocolConnectDevice> = devices
        .iter()
        .map(|(id, info)| ProtocolConnectDevice {
            id: id.clone(),
            name: info.name.clone(),
            // `DeviceType` is an open enum. An unknown value has no variant name.
            device_type: info
                .device_type
                .enum_value()
                .map(|kind| format!("{kind:?}"))
                .unwrap_or_default(),
        })
        .collect();

    list.sort_by(|a, b| a.id.cmp(&b.id));

    debug!(
        "notify_devices: cluster carried {} device(s), active={}",
        list.len(),
        active_device_id
    );

    let fingerprint = DevicesFingerprint {
        active_device_id: active_device_id.to_string(),
        devices: list.clone(),
    };
    let mut last = LAST_DEVICES_FINGERPRINT
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    if last.as_ref() == Some(&fingerprint) {
        return;
    }
    *last = Some(fingerprint);
    drop(last);

    if let Some(callback) = registered_callback(&CONTROL_CALLBACKS.devices) {
        let stamp = stamped_snapshot(|stamp| stamp);
        send_devices_snapshot(callback, stamp, active_device_id, &list);
    }
}

/// Creates the standard ConnectConfig for Spirc.
pub(crate) fn create_connect_config(device_name: &str) -> ConnectConfig {
    ConnectConfig {
        name: device_name.to_string(),
        device_type: DeviceType::Computer,
        initial_volume: u16::MAX,
        emit_set_queue_events: true,
        ..Default::default()
    }
}

pub(crate) fn configured_connect_device_name() -> Option<String> {
    CONNECT_DEVICE_NAME_SETTING
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
}

/// Creates Spirc and starts its background task.
///
/// The returned objects are deliberately local to the initialization transaction. The caller
/// publishes the `Spirc` and task handle together with the Session, Player, Mixer, and listener
/// handles only after every required constructor has succeeded. Keeping this function free of
/// global stores means a failed `Spirc::new` cannot leave a half-built generation reachable by
/// commands or teardown.
pub(crate) async fn create_spirc(
    session: &Session,
    credentials: &librespot_core::authentication::Credentials,
    player: Arc<Player>,
    mixer: Arc<SoftMixer>,
) -> Result<(Arc<Spirc>, JoinHandle<()>), InitializationFailure> {
    let device_name = configured_connect_device_name().ok_or(InitializationFailure::Transient)?;
    let connect_config = create_connect_config(&device_name);

    let (spirc, spirc_task) = Spirc::new(
        connect_config,
        session.clone(),
        credentials.clone(),
        player,
        mixer as Arc<dyn Mixer>,
    )
    .await
    .map_err(|error| classify_initialization_error(&error))?;

    let spirc_arc = Arc::new(spirc);
    let spirc_task = RUNTIME.spawn(spirc_task);

    debug!(
        "[WAKE +{}ms] Spirc constructed for pending generation",
        elapsed_since_wake_ms()
    );

    Ok((spirc_arc, spirc_task))
}

/// Asks for the cluster once, because subscribing to it is not enough to be told what it is.
///
/// **The dealer only pushes changes.** librespot registers its own device and receives the
/// current cluster in the *HTTP response* to that PUT — which this app's separate dealer
/// subscription never sees. Measured on 2026-08-13: registration completed at :04.702 and the
/// first push arrived at :27.035, twenty-three seconds later, and only because a phone
/// connected. With nothing else on the account, Speakers stayed empty indefinitely while a
/// Connect-enabled stereo sat there reachable.
///
/// So this registers a **hidden member** — `can_be_player: false, hidden: true` — the way any
/// pure controller does, and reads the cluster out of the reply. Hidden because this is not a
/// second playback device: librespot already registered the real one under its own id, and
/// re-PUTing that id with a partial state would disturb its registration rather than ask a
/// question.
/// The returned handle belongs to the session generation and must be retained until teardown.
pub(crate) fn spawn_initial_cluster_fetch(session: &Session, generation: u64) -> JoinHandle<()> {
    let session = session.clone();

    RUNTIME.spawn(async move {
        // The connection id is assigned over the dealer websocket, which is launched
        // alongside the session rather than before it, so it can be a moment behind.
        let mut connection_id = String::new();
        for _ in 0..40 {
            connection_id = session.connection_id();
            if !connection_id.is_empty() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(250)).await;
        }

        if connection_id.is_empty() {
            debug!("Initial cluster fetch: no connection id, giving up");
            return;
        }

        if !listener_may_act(generation, SESSION_GENERATION.load(Ordering::SeqCst)) {
            return;
        }

        match fetch_cluster(&session).await {
            Ok(cluster) => {
                // Again, after the request rather than only before it. A cluster describes an
                // account, and a logout can land inside this call — `spotty_playback_cleanup` empties
                // the snapshot caches, and applying this would fill them straight back up and
                // publish the previous account's devices, queue and playback state to whoever
                // signs in next. The check before the request cannot see that; only this one
                // can.
                if !listener_may_act(generation, SESSION_GENERATION.load(Ordering::SeqCst)) {
                    debug!("Initial cluster fetch: superseded while in flight, discarding");
                    return;
                }

                debug!(
                    "Initial cluster fetch: {} device(s), active={}",
                    cluster.device.len(),
                    cluster.active_device_id
                );
                // Same mapping a pushed update gets. The offer gate discards this snapshot
                // when a dealer push for this generation already won, so a slower HTTP reply
                // cannot last-write-win a newer cluster under a later stamp.
                offer_cluster(ClusterOrigin::BootstrapFetch, generation, cluster);
            }
            Err(e) => debug!("Initial cluster fetch failed: {}", e),
        }
    })
}

/// Registers a hidden connect-state member and returns the cluster the service answers with.
pub(crate) async fn fetch_cluster(session: &Session) -> Result<Cluster, String> {
    use protobuf::Message;

    let mut request = PutStateRequest::new();
    request.member_type = MemberType::CONNECT_STATE.into();

    let device = request.device.mut_or_insert_default();
    let info = device.device_info.mut_or_insert_default();
    let capabilities = info.capabilities.mut_or_insert_default();
    capabilities.can_be_player = false;
    capabilities.hidden = true;
    capabilities.needs_full_player_state = true;

    // A member id of our own, distinct from the one librespot registered.
    let endpoint = format!(
        "/connect-state/v1/devices/hobs_{}",
        session.device_id().chars().take(32).collect::<String>()
    );

    let mut headers = http::HeaderMap::new();
    headers.insert(
        "x-spotify-connection-id",
        session
            .connection_id()
            .parse()
            .map_err(|_| "connection id is not a valid header value".to_string())?,
    );

    let bytes = session
        .spclient()
        .request_with_protobuf(&http::Method::PUT, &endpoint, Some(headers), &request)
        .await
        .map_err(|e| format!("{e:?}"))?;

    Cluster::parse_from_bytes(&bytes).map_err(|e| format!("could not parse cluster: {e:?}"))
}

/// Everything a cluster says, delivered to Swift. Shared by the push and the initial fetch,
/// so what the app learns cannot depend on which of the two told it.
///
/// Session-sourced clusters (HTTP bootstrap and dealer push) must enter through
/// [`offer_cluster`] so a slower bootstrap cannot last-write-win a newer push. This function
/// remains the single mapping onto active device, devices, playback, and queue.
/// `generation` is the origin session; mapping stops if that session has been replaced.
///
/// Our own activity is derived from the cluster rather than inferred from whichever command
/// ran last. This is the same comparison `SpircTask` makes internally; Spotty runs a second
/// subscription to the same dealer topic and has to reach the same conclusion, or playback
/// routing and the UI disagree.
///
/// The device list rides along and used to be dropped on the floor, so Swift asked
/// `/me/player/devices` for what was already here.
pub(crate) fn apply_cluster(generation: u64, cluster: Cluster) {
    if !cluster_generation_current(generation) {
        return;
    }
    let is_active_device =
        is_active_in_cluster(&cluster.active_device_id, current_device_id().as_deref());
    set_active_device(is_active_device);
    if !cluster_generation_current(generation) {
        return;
    }
    notify_devices(&cluster.device, &cluster.active_device_id);

    if let Some(player_state) = cluster.player_state.into_option() {
        if !cluster_generation_current(generation) {
            return;
        }
        send_playback_state(&player_state, is_active_device);
        if !cluster_generation_current(generation) {
            return;
        }
        process_and_send_queue(player_state);
    }
}

/// Subscribes to cluster updates on the session's dealer and spawns a task to process them.
/// The returned handle belongs to the session generation and must be retained until teardown.
///
/// When the stream ends, the Spirc it belonged to is gone, so this triggers reconnection —
/// but only for the current generation, and only outside an intentional teardown.
pub(crate) fn spawn_cluster_listener(
    session: &Session,
    generation: u64,
) -> Result<JoinHandle<()>, String> {
    let queue_stream = session
        .dealer()
        .listen_for(
            "hm://connect-state/v1/cluster",
            librespot_core::dealer::protocol::Message::from_raw::<ClusterUpdate>,
        )
        .map_err(|e| format!("Failed to subscribe to cluster updates: {}", e))?;

    let task = RUNTIME.spawn(async move {
        debug!("Cluster listener started (generation={})", generation);
        let mut stream = queue_stream;
        while let Some(msg_result) = stream.next().await {
            // Same rule as the player event listener: a superseded cluster listener keeps
            // receiving until its stream actually closes, and its updates describe a session
            // that has been replaced. Checking only after the stream ends, as this used to,
            // leaves every message before that point unguarded.
            if !listener_may_act(generation, SESSION_GENERATION.load(Ordering::SeqCst)) {
                continue;
            }

            match msg_result {
                Ok(cluster_update) => {
                    if let Some(cluster) = cluster_update.cluster.into_option() {
                        offer_cluster(ClusterOrigin::PushedUpdate, generation, cluster);
                    }
                }
                Err(e) => {
                    debug!("Failed to parse cluster update: {:?}", e);
                }
            }
        }

        debug!("Cluster listener ended (generation={})", generation);

        let current_gen = SESSION_GENERATION.load(Ordering::SeqCst);
        if !should_recover_after_cluster_end(generation, current_gen, teardown_in_progress()) {
            debug!(
                "Cluster listener ended without recovery (generation={}, current={})",
                generation, current_gen
            );
            return;
        }

        let intent = RecoveryIntent::capture();
        mark_disconnected("Cluster listener ended unexpectedly");
        spawn_reconnection_loop(intent);
    });

    Ok(task)
}
