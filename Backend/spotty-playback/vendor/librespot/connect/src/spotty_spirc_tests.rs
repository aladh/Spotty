use super::*;
use super::spotty_transport_fixture::task;
use futures_util::FutureExt;

#[tokio::test]
async fn spotty_delayed_paused_load_event_cannot_undo_a_newer_resume() {
    for loading in [false, true] {
        let mut task = task();
        task.play_request_id = Some(7);
        task.play_status = if loading {
            SpircPlayStatus::LoadingPause {
                position_ms: 152_000,
            }
        } else {
            SpircPlayStatus::Paused {
                position_ms: 152_000,
                preloading_of_next_track_triggered: false,
            }
        };
        let track_id = SpotifyUri::from_uri("spotify:track:0000000000000000000001").unwrap();
        // The adapter's event receiver has already seen Paused and authorized resume,
        // but Spirc can select the Play command before draining its own Paused event.
        task.handle_play();
        task.handle_player_event(PlayerEvent::Paused {
            track_id: track_id.clone(),
            play_request_id: 7,
            position_ms: 152_000,
        })
        .unwrap();
        task.handle_player_event(PlayerEvent::Playing {
            track_id,
            play_request_id: 7,
            position_ms: 152_000,
        })
        .unwrap();
        assert!(matches!(task.play_status, SpircPlayStatus::Playing { .. }));
        task.connect_state.set_status(&task.play_status);
        assert!(!task.connect_state.player().is_paused);
    }
}

#[tokio::test]
async fn spotty_delayed_playing_load_event_cannot_undo_a_newer_pause() {
    let mut task = task();
    task.play_request_id = Some(7);
    task.play_status = SpircPlayStatus::LoadingPlay {
        position_ms: 152_000,
    };
    let track_id = SpotifyUri::from_uri("spotify:track:0000000000000000000001").unwrap();
    task.handle_pause();
    task.handle_player_event(PlayerEvent::Playing {
        track_id: track_id.clone(),
        play_request_id: 7,
        position_ms: 152_000,
    })
    .unwrap();
    assert!(matches!(
        task.play_status,
        SpircPlayStatus::LoadingPause { .. }
    ));
    task.handle_player_event(PlayerEvent::Paused {
        track_id,
        play_request_id: 7,
        position_ms: 152_000,
    })
    .unwrap();
    assert!(matches!(task.play_status, SpircPlayStatus::Paused { .. }));
}

#[tokio::test]
async fn spotty_pause_command_updates_connect_before_the_player_event() {
    let mut task = task();
    task.connect_state.set_active(true);
    task.play_request_id = Some(7);
    task.play_status = SpircPlayStatus::Playing {
        nominal_start_time: task.now_ms() - 152_000,
        preloading_of_next_track_triggered: false,
    };
    // The transfer adapter uses this same command path. State changes before notify's
    // transport request; an offline test need not complete that request.
    let _ = task.handle_command(SpircCommand::Pause).now_or_never();
    assert!(matches!(task.play_status, SpircPlayStatus::Paused { .. }));
    assert!(task.connect_state.player().is_paused);
    task.handle_player_event(PlayerEvent::Paused {
        track_id: SpotifyUri::from_uri("spotify:track:0000000000000000000001").unwrap(),
        play_request_id: 7,
        position_ms: 152_075,
    })
    .unwrap();
    assert_eq!(
        task.connect_state.player().position_as_of_timestamp,
        152_075
    );
}

#[tokio::test]
async fn spotty_ordered_selection_retains_modes_without_reshuffling_its_tracks() {
    use crate::model::Options;
    let mut task = task();
    let tracks = vec![
        "spotify:track:0000000000000000000001".to_owned(),
        "spotify:track:0000000000000000000002".to_owned(),
        "spotify:track:0000000000000000000003".to_owned(),
    ];
    task.handle_load(
        LoadRequest::from_tracks(
            tracks.clone(),
            LoadRequestOptions {
                context_options: Some(LoadContextOptions::Options(Options {
                    shuffle: true,
                    repeat: true,
                    repeat_track: true,
                })),
                preserve_track_order: true,
                ..Default::default()
            },
        ),
        None,
        None,
    )
    .await
    .unwrap();
    assert_eq!(
        task.connect_state.current_track(|track| track.uri.clone()),
        tracks[0]
    );
    assert!(task.connect_state.shuffling_context());
    assert!(task.connect_state.repeat_context());
    assert!(task.connect_state.repeat_track());
    assert_eq!(
        task.connect_state
            .player()
            .next_tracks
            .iter()
            .take(2)
            .map(|track| track.uri.clone())
            .collect::<Vec<_>>(),
        tracks[1..],
    );
}

#[tokio::test]
async fn spotty_self_transfer_does_not_wait_inside_the_dealer_command_handler() {
    let mut task = task();
    let outcome = task
        .handle_command(SpircCommand::Transfer(None, None))
        .now_or_never();
    assert!(
        matches!(outcome, Some(Ok(()))),
        "the handler must return before polling the HTTP reply so Dealer can acknowledge it"
    );
    assert!(task.pending_transfer.is_some());
    // A second local transfer cannot replace the owned in-flight request.
    assert!(
        task.handle_command(SpircCommand::Transfer(None, None))
            .await
            .is_err()
    );
    task.pending_transfer = None;
}

#[tokio::test]
async fn spotty_own_cluster_echo_does_not_schedule_another_state_update() {
    let mut task = task();
    task.connect_state.set_active(true);
    let local = task.session.device_id().to_owned();
    let update = |changed| ClusterUpdate {
        cluster: MessageField::some(Cluster {
            active_device_id: local.clone(),
            ..Default::default()
        }),
        devices_that_changed: vec![changed],
        ..Default::default()
    };
    task.handle_cluster_update(update(local.clone()))
        .await
        .unwrap();
    assert!(
        !task.update_state,
        "self echoes must leave context restoration runnable"
    );
    task.handle_cluster_update(update("other-client".into()))
        .await
        .unwrap();
    assert!(
        task.update_state,
        "retain the upstream refresh for other clients"
    );
}

#[tokio::test]
async fn spotty_observed_transfer_waits_for_context_and_cancellation_closes_the_receipt() {
    use crate::protocol::{context_track::ContextTrack, player::ProvidedTrack};
    let mut task = task();
    let uri = "spotify:track:0000000000000000000001";
    let context = "spotify:playlist:fixture";
    task.connect_state.begin_observed_transfer(PlayerState {
        context_uri: context.into(),
        track: MessageField::some(ProvidedTrack {
            uri: uri.into(),
            ..Default::default()
        }),
        ..Default::default()
    });
    task.transfer_state = Some(TransferState::default());
    let (sender, mut restored) = oneshot::channel();
    task.transfer_restored = Some(sender);
    task.context_resolver.add(ResolveContext::from_uri(
        context,
        uri,
        ContextType::Default,
        ContextAction::Replace,
    ));
    assert!(matches!(
        restored.try_recv(),
        Err(oneshot::error::TryRecvError::Empty)
    ));
    assert!(task.handle_next_context(Ok(Context {
        uri: Some(context.into()),
        pages: vec![ContextPage {
            tracks: vec![ContextTrack {
                uri: Some(uri.into()),
                ..Default::default()
            }],
            ..Default::default()
        }],
        ..Default::default()
    })));
    assert_eq!(restored.try_recv(), Ok(()));
    assert!(task.transfer_state.is_none());

    let (sender, mut cancelled) = oneshot::channel();
    task.transfer_restored = Some(sender);
    task.transfer_state = Some(TransferState::default());
    task.cancel_observed_transfer();
    assert!(task.transfer_state.is_none());
    assert!(matches!(
        cancelled.try_recv(),
        Err(oneshot::error::TryRecvError::Closed)
    ));
}

#[tokio::test]
async fn spotty_expired_resume_does_not_claim_a_later_inbound_transfer() {
    use crate::protocol::{context_track::ContextTrack, playback::Playback};
    let mut task = task();
    let context = "spotify:playlist:fixture";
    let snapshot = PlayerState {
        context_uri: context.into(),
        track: MessageField::some(ProvidedTrack {
            uri: "spotify:track:0000000000000000000001".into(),
            ..Default::default()
        }),
        position_as_of_timestamp: 152_000,
        ..Default::default()
    };
    let incoming = TransferState {
        current_session: MessageField::some(crate::protocol::session::Session {
            context: MessageField::some(Context {
                uri: Some(context.into()),
                ..Default::default()
            }),
            ..Default::default()
        }),
        playback: MessageField::some(Playback {
            current_track: MessageField::some(ContextTrack {
                uri: Some("spotify:track:0000000000000000000002".into()),
                ..Default::default()
            }),
            is_paused: Some(false),
            ..Default::default()
        }),
        ..Default::default()
    };
    let (sender, receiver) = oneshot::channel();
    task.transfer_snapshot = Some(ObservedTransfer {
        snapshot: snapshot.clone(),
        restored: sender,
    });
    drop(receiver); // The observed-resume deadline expired before Dealer delivered a transfer.
    assert!(task.take_observed_transfer(&incoming).unwrap().is_none());
    assert!(task.transfer_snapshot.is_none());

    // A live resume still rejects conflicting evidence and closes its waiting receipt.
    let (sender, mut receiver) = oneshot::channel();
    task.transfer_snapshot = Some(ObservedTransfer {
        snapshot,
        restored: sender,
    });
    assert!(task.take_observed_transfer(&incoming).is_err());
    assert!(matches!(
        receiver.try_recv(),
        Err(oneshot::error::TryRecvError::Closed)
    ));
}

#[tokio::test]
async fn spotty_failed_finish_retains_transfer_until_later_context_restores_the_queue() {
    use crate::protocol::context_track::ContextTrack;
    let mut task = task();
    let mut current = ProvidedTrack {
        uri: "spotify:track:0000000000000000000001".into(),
        provider: "autoplay".into(),
        ..Default::default()
    };
    current
        .metadata
        .insert("autoplay.is_autoplay".into(), "true".into());
    let next = ProvidedTrack {
        uri: "spotify:track:0000000000000000000002".into(),
        provider: "autoplay".into(),
        ..Default::default()
    };
    task.connect_state.begin_observed_transfer(PlayerState {
        track: MessageField::some(current.clone()),
        next_tracks: vec![next.clone()],
        ..Default::default()
    });
    task.transfer_state = Some(TransferState::default());
    let (sender, mut restored) = oneshot::channel();
    task.transfer_restored = Some(sender);
    let context = "spotify:playlist:fixture";
    for kind in [ContextType::Default, ContextType::Autoplay] {
        task.context_resolver.add(ResolveContext::from_uri(
            context,
            &current.uri,
            kind,
            ContextAction::Replace,
        ));
    }
    let changed_context = || Context {
        uri: Some(context.into()),
        pages: vec![ContextPage {
            tracks: vec![ContextTrack {
                uri: Some("spotify:track:0000000000000000000003".into()),
                ..Default::default()
            }],
            ..Default::default()
        }],
        ..Default::default()
    };
    // Default context resolves first, but finishing needs the absent autoplay context.
    assert!(!task.handle_next_context(Ok(changed_context())));
    assert!(task.transfer_state.is_some());
    assert!(matches!(
        restored.try_recv(),
        Err(oneshot::error::TryRecvError::Empty)
    ));

    // The later context must finish the retained transfer, not acknowledge ordinary setup
    // that replaces the observed occurrence and queue with this changed playlist's first item.
    assert!(task.handle_next_context(Ok(changed_context())));
    assert!(task.transfer_state.is_none());
    assert_eq!(restored.try_recv(), Ok(()));
    assert_eq!(task.connect_state.player().track.as_ref(), Some(&current));
    assert_eq!(task.connect_state.player().next_tracks, vec![next]);
}
