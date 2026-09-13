use super::*;
use crate::core::SessionConfig;
use crate::protocol::connect::PutStateRequest;
use crate::protocol::player::{ContextPlayerOptions, ProvidedTrack};
use crate::protocol::transfer_state::TransferState;
use crate::protocol::{context::Context, context_page::ContextPage, context_track::ContextTrack};
use crate::state::context::StateContext;
use protobuf::{Message, MessageField};

fn track(uri: &str, uid: &str) -> ProvidedTrack {
    let mut track = ProvidedTrack {
        uri: format!("spotify:track:{uri}"),
        uid: uid.into(),
        provider: "context".into(),
        ..Default::default()
    };
    track.metadata.insert("fixture".into(), uid.into());
    track
}

#[tokio::test]
async fn spotty_hydration_transfer_resolution_end_and_cross_client_snapshot_agree() {
    let session = Session::new(SessionConfig::default(), None);
    let mut state = ConnectState::new(ConnectConfig::default(), &session);
    let current = track("0000000000000000000001", "current");
    let next = track("0000000000000000000002", "next");
    let duplicate = track("0000000000000000000002", "duplicate-occurrence");
    let snapshot = PlayerState {
        context_uri: "spotify:playlist:fixture".into(),
        track: MessageField::some(current.clone()),
        next_tracks: vec![next.clone(), duplicate.clone()],
        options: MessageField::some(ContextPlayerOptions {
            shuffling_context: true,
            repeating_context: true,
            ..Default::default()
        }),
        position_as_of_timestamp: 152_000,
        duration: 240_000,
        ..Default::default()
    };
    // The playlist has changed since Spotify saved the session; its first item is unrelated.
    state.context = Some(StateContext {
        tracks: vec![track("0000000000000000000003", "new-first"), next.clone()].into(),
        metadata: Default::default(),
        restrictions: None,
        index: Default::default(),
    });
    state.set_track(current.clone());
    let mut transfer = TransferState::default();
    state.handle_initial_transfer(&mut transfer, Some(snapshot.context_uri.clone()));
    state.begin_observed_transfer(snapshot.clone());
    state.set_active(true);
    state.set_status(&SpircPlayStatus::Paused {
        position_ms: 152_000,
        preloading_of_next_track_triggered: false,
    });
    state.update_position(152_000, 1_000);
    assert_eq!(state.player().track.as_ref(), Some(&current));
    assert_eq!(state.player().next_tracks, snapshot.next_tracks);
    assert_eq!(state.player().duration, snapshot.duration);
    assert!(state.shuffling_context() && state.repeat_context());

    state
        .update_context(
            Context {
                uri: Some(snapshot.context_uri.clone()),
                pages: vec![ContextPage {
                    tracks: vec![ContextTrack {
                        uri: Some("spotify:track:0000000000000000000003".into()),
                        uid: Some("new-first".into()),
                        ..Default::default()
                    }],
                    ..Default::default()
                }],
                ..Default::default()
            },
            context::ContextType::Default,
        )
        .unwrap();
    assert_eq!(state.player().next_tracks, snapshot.next_tracks);
    state.finish_transfer(transfer).unwrap();
    state.set_status(&SpircPlayStatus::Playing {
        nominal_start_time: 0,
        preloading_of_next_track_triggered: false,
    });
    let confirmed =
        PutStateRequest::parse_from_bytes(&state.request.write_to_bytes().unwrap()).unwrap();
    assert!(confirmed.is_active && !confirmed.device.player_state.is_paused);
    assert_eq!(confirmed.device.player_state.track.as_ref(), Some(&current));
    assert_eq!(
        confirmed.device.player_state.position_as_of_timestamp,
        152_000
    );
    assert_eq!(
        confirmed.device.player_state.next_tracks,
        snapshot.next_tracks
    );
    assert_eq!(confirmed.device.player_state.options, snapshot.options);

    // Spirc's EndOfTrack path advances through this production method.
    state.next_track().unwrap();
    state.update_position(250, 2_000);
    let cross_client =
        PutStateRequest::parse_from_bytes(&state.request.write_to_bytes().unwrap()).unwrap();
    assert_eq!(cross_client.device.player_state.track.as_ref(), Some(&next));
    assert_eq!(
        cross_client.device.player_state.next_tracks.first(),
        Some(&duplicate)
    );
    assert_eq!(
        cross_client.device.player_state.position_as_of_timestamp,
        250
    );
    assert_eq!(cross_client.device.player_state.options, snapshot.options);

    state.set_status(&SpircPlayStatus::Paused {
        position_ms: 250,
        preloading_of_next_track_triggered: false,
    });
    // Disconnect updates the timestamp after the user has left the session paused.
    state.update_position_in_relation(32_000);
    let reopened =
        PutStateRequest::parse_from_bytes(&state.request.write_to_bytes().unwrap()).unwrap();
    assert_eq!(reopened.device.player_state.track.as_ref(), Some(&next));
    assert_eq!(reopened.device.player_state.position_as_of_timestamp, 250);
    assert!(reopened.device.player_state.is_paused);
    assert_eq!(reopened.device.player_state.options, snapshot.options);
}
