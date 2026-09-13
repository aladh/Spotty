use super::*;
use crate::core::SessionConfig;
use crate::playback::{
    audio_backend::{Sink, SinkResult},
    config::PlayerConfig,
    convert::Converter,
    decoder::AudioPacket,
    mixer::{MixerConfig, NoOpVolume, softmixer::SoftMixer},
};
use futures_util::{FutureExt, stream};

struct SilentSink;
impl Sink for SilentSink {
    fn write(&mut self, _: AudioPacket, _: &mut Converter) -> SinkResult<()> {
        panic!("command scheduling tests must not render audio")
    }
}

// Exercise the actual command handler without connecting a Session, resolving a context,
// or loading a track. The Player remains stopped and all Dealer streams stay pending.
fn task() -> SpircTask {
    let session = Session::new(SessionConfig::default(), None);
    let player = Player::new(
        PlayerConfig::default(),
        session.clone(),
        Box::new(NoOpVolume),
        || Box::new(SilentSink),
    );
    SpircTask {
        player,
        mixer: Arc::new(SoftMixer::open(MixerConfig::default()).unwrap()),
        connect_state: ConnectState::new(ConnectConfig::default(), &session),
        connect_established: true,
        play_request_id: None,
        play_status: SpircPlayStatus::Stopped,
        connection_id_update: Box::pin(stream::pending()),
        connect_state_update: Box::pin(stream::pending()),
        connect_state_volume_update: Box::pin(stream::pending()),
        connect_state_logout_request: Box::pin(stream::pending()),
        playlist_update: Box::pin(stream::pending()),
        session_update: Box::pin(stream::pending()),
        connect_state_command: Box::pin(stream::pending()),
        user_attributes_update: Box::pin(stream::pending()),
        user_attributes_mutation: Box::pin(stream::pending()),
        commands: None,
        player_events: None,
        context_resolver: ContextResolver::new(session.clone()),
        emit_set_queue_events: false,
        shutdown: false,
        session,
        transfer_state: None,
        pending_transfer: None,
        transfer_snapshot: None,
        transfer_restored: None,
        update_volume: false,
        update_state: false,
        spirc_id: 0,
    }
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
