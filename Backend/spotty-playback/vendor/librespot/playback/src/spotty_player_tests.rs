use super::*;
use crate::{audio_backend::SinkResult, mixer::NoOpVolume};
use librespot_core::{SessionConfig, audio_key::AudioKeyError};

struct SilentSink(Arc<AtomicUsize>);
impl Sink for SilentSink {
    fn stop(&mut self) -> SinkResult<()> {
        self.0.fetch_add(1, Ordering::Relaxed);
        Ok(())
    }
    fn write(&mut self, _: AudioPacket, _: &mut Converter) -> SinkResult<()> {
        panic!("synthetic load failures must never produce audio")
    }
}

fn fixture() -> (
    PlayerInternal,
    mpsc::UnboundedSender<PlayerCommand>,
    PlayerEventChannel,
    Arc<AtomicUsize>,
) {
    let (commands, receiver) = mpsc::unbounded_channel();
    let (events, event_receiver) = mpsc::unbounded_channel();
    let stops = Arc::new(AtomicUsize::new(0));
    let config = PlayerConfig::default();
    let player = PlayerInternal {
        session: Session::new(
            SessionConfig {
                device_id: "0123456789abcdef0123456789abcdef01234567".into(),
                ..SessionConfig::default()
            },
            None,
        ),
        config,
        commands: receiver,
        load_handles: Arc::new(Mutex::new(HashMap::new())),
        state: PlayerState::Stopped,
        preload: PlayerPreload::None,
        sink: Box::new(SilentSink(stops.clone())),
        sink_status: SinkStatus::Running,
        sink_event_callback: None,
        volume_getter: Box::new(NoOpVolume),
        event_senders: vec![events],
        converter: Converter::new(None),
        normalisation_peaks: [0.0; 2],
        normalisation_integrators: [0.0; 2],
        normalisation_channel: 0,
        normalisation_knee_factor: 0.0,
        auto_normalise_as_album: false,
        player_id: 0,
        play_request_id_generator: SeqGenerator::new(0),
        last_progress_update: Instant::now(),
        local_file_lookup: Arc::new(create_local_file_lookup(&[])),
    };
    (player, commands, event_receiver, stops)
}

fn track() -> SpotifyUri {
    SpotifyUri::from_uri("spotify:track:0000000000000000000001").unwrap()
}

fn poll_once(player: &mut PlayerInternal) {
    let waker = futures_util::task::noop_waker();
    assert!(
        Pin::new(player)
            .poll(&mut Context::from_waker(&waker))
            .is_pending()
    );
}

#[tokio::test]
async fn spotty_current_refusal_stops_once_without_skip_event() {
    let (mut player, _commands, mut events, stops) = fixture();
    player.state = PlayerState::Loading {
        loader: Box::pin(future::ready(Err(LoadFailure::AudioKeyRefused)).fuse()),
        track_id: track(),
        start_playback: true,
        play_request_id: 42,
    };
    poll_once(&mut player);
    assert!(matches!(player.state, PlayerState::Stopped));
    assert_eq!(stops.load(Ordering::Relaxed), 1);
    assert!(matches!(
        events.try_recv().unwrap(),
        PlayerEvent::AudioKeyRefused {
            play_request_id: 42,
            ..
        }
    ));
    assert!(matches!(
        events.try_recv().unwrap(),
        PlayerEvent::Stopped {
            play_request_id: 42,
            ..
        }
    ));
    assert!(events.try_recv().is_err());
    poll_once(&mut player);
    assert_eq!(stops.load(Ordering::Relaxed), 1);
    assert!(events.try_recv().is_err());
}

#[tokio::test]
async fn spotty_ordinary_unavailable_still_emits_skip_policy_event() {
    let (mut player, _commands, mut events, stops) = fixture();
    player.state = PlayerState::Loading {
        loader: Box::pin(future::ready(Err(LoadFailure::Unavailable)).fuse()),
        track_id: track(),
        start_playback: true,
        play_request_id: 42,
    };
    poll_once(&mut player);
    assert!(matches!(
        events.try_recv().unwrap(),
        PlayerEvent::Unavailable {
            play_request_id: 42,
            ..
        }
    ));
    assert!(events.try_recv().is_err());
    assert_eq!(stops.load(Ordering::Relaxed), 0);
}

#[tokio::test]
async fn spotty_preload_refusal_neither_stops_nor_marks_occurrence_unavailable() {
    let (mut player, _commands, mut events, stops) = fixture();
    player.state = PlayerState::Loading {
        loader: Box::pin(future::pending().fuse()),
        track_id: track(),
        start_playback: true,
        play_request_id: 42,
    };
    player.preload = PlayerPreload::Loading {
        loader: Box::pin(future::ready(Err(LoadFailure::AudioKeyRefused)).fuse()),
        track_id: track(),
    };
    poll_once(&mut player);
    assert!(matches!(
        player.state,
        PlayerState::Loading {
            play_request_id: 42,
            ..
        }
    ));
    assert!(matches!(player.preload, PlayerPreload::None));
    assert!(events.try_recv().is_err());
    assert_eq!(stops.load(Ordering::Relaxed), 0);
}

#[test]
fn spotty_refusal_is_structural_and_requires_decoder_failure() {
    let refused = explicitly_refused_key(&AudioKeyError::AesKey.into());
    let timeout = explicitly_refused_key(&AudioKeyError::Timeout.into());
    let channel = explicitly_refused_key(&AudioKeyError::Channel.into());
    assert!(refused);
    assert!(!timeout);
    assert!(!channel);
    let invalid_audio = std::io::Cursor::new(vec![0u8; 512]);
    let failed = SymphoniaDecoder::new(invalid_audio, Hint::new()).is_err();
    assert!(failed);
    assert!(stop_for_key_refusal(refused, failed));
    assert!(!stop_for_key_refusal(timeout, failed));
    assert!(!stop_for_key_refusal(channel, failed));
    assert!(!stop_for_key_refusal(refused, false));
    let event = PlayerEvent::AudioKeyRefused {
        play_request_id: 42,
        track_id: track(),
    };
    assert_eq!(event.get_play_request_id(), Some(42));
}

#[test]
fn spotty_unencrypted_audio_remains_playable_after_key_refusal() {
    let input = std::io::Cursor::new(include_bytes!("../tests/fixtures/silence.flac").to_vec());
    let decoded = SymphoniaDecoder::new(input, Hint::new());
    assert!(decoded.is_ok());
    assert!(!stop_for_key_refusal(
        explicitly_refused_key(&AudioKeyError::AesKey.into()),
        decoded.is_err()
    ));
    let mut decoder = decoded.unwrap();
    assert!(decoder.next_packet().unwrap().is_some());
}
