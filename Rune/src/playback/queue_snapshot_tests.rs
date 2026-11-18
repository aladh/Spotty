use super::*;
use std::{cell::RefCell, rc::Rc};

#[test]
fn cluster_delivers_an_owned_queue_and_connection_at_the_same_revision() {
    let _fixture = ObservationFixture::new();
    let generation = SESSION_GENERATION.load(Ordering::SeqCst);

    let captured = Rc::new(RefCell::new(Vec::new()));
    let output = captured.clone();
    let _observer = client::TestObserver::install(move |event| {
        let client::Observation::Cluster(cluster) = event else {
            panic!("expected one aggregate observation");
        };
        // Delivery can call back into both state and revision accessors.
        assert_eq!(with_connection(|c| c.is_active_device), false);
        assert!(stamped_snapshot(|stamp| stamp.revision) > cluster.sequence);
        output.borrow_mut().push(cluster);
    });

    with_connection(|c| {
        c.device_id = Some("local".into());
        c.is_active_device = true;
    });
    let row = |uri: &str, uid: &str| ProvidedTrack {
        uri: uri.into(),
        uid: uid.into(),
        provider: "queue".into(),
        ..Default::default()
    };
    let mut first = row("spotify:track:duplicate", "occ-a");
    first.metadata.insert("is_queued".into(), "true".into());
    first
        .restrictions
        .mut_or_insert_default()
        .disallow_resuming_reasons
        .push("not_active_device".into());
    let mut previous = row("spotify:track:previous", "occ-prev");
    previous.removed.push("removed-reason".into());
    previous.blocked.push("blocked-reason".into());
    let mut player = PlayerState {
        context_uri: "spotify:playlist:fixture".into(),
        track: protobuf::MessageField::some(row("spotify:track:current", "occ-now")),
        queue_revision: "fixture-revision".into(),
        next_tracks: vec![
            first,
            row("spotify:track:duplicate", "occ-b"),
            row("spotify:delimiter", ""),
        ],
        prev_tracks: vec![previous],
        ..Default::default()
    };
    player
        .restrictions
        .mut_or_insert_default()
        .disallow_set_queue_reasons
        .push("not_allowed".into());
    let cluster = Cluster {
        active_device_id: "remote".into(),
        player_state: protobuf::MessageField::some(player),
        ..Default::default()
    };
    apply_cluster(generation, ClusterOrigin::PushedUpdate, cluster);

    let mut captured = captured.borrow_mut();
    assert_eq!(captured.len(), 1);
    let snapshot = captured.pop().unwrap();
    let connection_snapshot = snapshot.connection;
    let playback = snapshot.playback.unwrap();
    let queue = snapshot.queue.unwrap();
    assert_eq!(snapshot.generation, generation);
    assert_eq!(queue.generation, generation);
    assert_eq!(playback.generation, generation);
    assert_eq!(connection_snapshot.generation, generation);
    assert_eq!(queue.sequence, snapshot.sequence);
    assert_eq!(playback.sequence, snapshot.sequence);
    assert_eq!(connection_snapshot.sequence, snapshot.sequence);
    assert!(!connection_snapshot.local);
    assert_eq!(connection_snapshot.id.as_deref(), Some("local"));
    assert_eq!(snapshot.active.as_deref(), Some("remote"));
    assert_eq!(queue.revision.as_deref(), Some("fixture-revision"));
    assert_eq!(queue.context, "spotify:playlist:fixture");
    assert_eq!(queue.track, "spotify:track:current");
    assert_eq!(queue.next[0].uri, queue.next[1].uri);
    assert_eq!(queue.next[0].uid, "occ-a");
    assert_eq!(queue.next[1].uid, "occ-b");
    assert_eq!(queue.next[2].uri, "spotify:delimiter");
    assert_eq!(queue.next[0].metadata["is_queued"], "true");
    assert_eq!(
        queue.next[0].restrictions["disallow_resuming_reasons"],
        ["not_active_device"]
    );
    assert_eq!(queue.previous[0].removed, ["removed-reason"]);
    assert_eq!(queue.previous[0].blocked, ["blocked-reason"]);
    assert!(queue.removal_disallowed);
}
