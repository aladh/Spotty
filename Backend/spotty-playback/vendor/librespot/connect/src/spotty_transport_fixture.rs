use super::*;
use crate::core::SessionConfig;
use crate::playback::{
    audio_backend::{Sink, SinkResult},
    config::PlayerConfig,
    convert::Converter,
    decoder::AudioPacket,
    mixer::{MixerConfig, NoOpVolume, softmixer::SoftMixer},
};
use futures_util::stream;

struct SilentSink;
impl Sink for SilentSink {
    fn write(&mut self, _: AudioPacket, _: &mut Converter) -> SinkResult<()> {
        panic!("command scheduling tests must not render audio")
    }
}

// Exercise the actual command handler without connecting a Session, resolving a context,
// or loading a track. The Player remains stopped and all Dealer streams stay pending.
pub(super) fn task() -> SpircTask {
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

/// Offline access to the retained Spirc handler for adapter integration traces.
/// The player stays stopped, Dealer streams never connect, and the sink rejects audio.
#[cfg(feature = "spotty-test-harness")]
pub struct SpottyTransportFixture {
    task: SpircTask,
}

#[cfg(feature = "spotty-test-harness")]
impl SpottyTransportFixture {
    /// Begin a synthetic load with its desired transport and request identity.
    pub fn new(playing: bool, request: u64, position_ms: u32) -> Self {
        let mut task = task();
        task.play_request_id = Some(request);
        task.play_status = if playing {
            SpircPlayStatus::LoadingPlay { position_ms }
        } else {
            SpircPlayStatus::LoadingPause { position_ms }
        };
        Self { task }
    }

    /// Drive the same synchronous transition used by ordinary and transfer commands.
    pub fn command(&mut self, playing: bool) {
        if playing { self.task.handle_play(); } else { self.task.handle_pause(); }
    }

    /// Deliver one controlled event to the actual retained handler.
    pub fn deliver(&mut self, event: PlayerEvent) {
        self.task.handle_player_event(event).expect("synthetic event");
        self.task.connect_state.set_status(&self.task.play_status);
    }

    /// Current protocol position, for stale-load assertions.
    pub fn position_ms(&self) -> i64 {
        self.task.connect_state.player().position_as_of_timestamp
    }

    /// Whether a terminal event released the retained handler's current playback.
    pub fn is_stopped(&self) -> bool {
        matches!(self.task.play_status, SpircPlayStatus::Stopped)
    }

    /// Protocol transport state another Connect client consumes.
    pub fn is_paused(&self) -> bool {
        self.task.connect_state.player().is_paused
    }
}
