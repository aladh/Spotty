//! Playback commands and observations shared with the app session worker.

pub use crate::playback::connect::ClusterOrigin;
use crate::playback::*;
use serde::Serialize;
use std::collections::BTreeMap;
use std::sync::OnceLock;

#[derive(Clone, Debug)]
pub struct Playback {
    pub sequence: u64,
    pub generation: u64,
    pub position_ms: u32,
    pub duration_ms: u32,
    pub timestamp_ms: i64,
    pub playing: bool,
    pub unavailable: bool,
    pub rejected: bool,
    pub shuffle: bool,
    pub repeat_track: bool,
    pub repeat_context: bool,
    pub local: bool,
    pub track: String,
    pub context: Option<String>,
}

#[derive(Clone, Debug)]
pub struct Connection {
    pub sequence: u64,
    pub generation: u64,
    pub connected: bool,
    pub ready: bool,
    pub local: bool,
    pub resume_pending: bool,
    pub credentials_rejected: bool,
    pub id: Option<String>,
    pub error: Option<String>,
}

#[derive(Clone, Debug)]
pub struct Device {
    pub id: String,
    pub name: String,
    pub kind: String,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct QueueTrack {
    pub uri: String,
    pub uid: String,
    pub provider: String,
    pub metadata: BTreeMap<String, String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub removed: Vec<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub blocked: Vec<String>,
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub restrictions: BTreeMap<String, Vec<String>>,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub album_uri: String,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub disallow_reasons: Vec<String>,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub artist_uri: String,
}

#[derive(Clone, Debug)]
pub struct Queue {
    pub sequence: u64,
    pub generation: u64,
    pub revision: Option<String>,
    pub track: String,
    pub context: String,
    pub next: Vec<QueueTrack>,
    pub previous: Vec<QueueTrack>,
    pub removal_disallowed: bool,
}

#[derive(Clone, Debug)]
pub struct Cluster {
    pub source: ClusterOrigin,
    pub sequence: u64,
    pub generation: u64,
    pub active: Option<String>,
    pub local: Option<String>,
    pub connection: Connection,
    pub playback: Option<Playback>,
    pub queue: Option<Queue>,
    pub devices: Vec<Device>,
}

#[derive(Clone, Debug)]
pub enum Observation {
    Cluster(Cluster),
    Connection(Connection),
    Playback(Playback),
}

type Observer = Box<dyn Fn(Observation) + Send + Sync>;
type Audio = Box<dyn Fn(&[f32]) + Send + Sync>;
type AudioState = Box<dyn Fn(AudioControl) + Send + Sync>;

struct Client {
    observe: Observer,
    audio: Audio,
    audio_state: AudioState,
}

static CLIENT: OnceLock<Client> = OnceLock::new();

/// Installs the process player output. Observation and control receivers run on engine
/// threads and must return promptly. Borrowed PCM is delivered on the librespot producer
/// thread, where the receiver can pace decoding against the device ring.
pub fn install(
    observe: impl Fn(Observation) + Send + Sync + 'static,
    audio: impl Fn(&[f32]) + Send + Sync + 'static,
    audio_state: impl Fn(AudioControl) + Send + Sync + 'static,
) {
    let _ = CLIENT.set(Client {
        observe: Box::new(observe),
        audio: Box::new(audio),
        audio_state: Box::new(audio_state),
    });
}

pub(crate) fn publish_cluster(cluster: impl FnOnce() -> Cluster) {
    if CLIENT.get().is_some() {
        publish_observation(Observation::Cluster(cluster()));
        return;
    }
    #[cfg(test)]
    if TEST_OBSERVER.with(|slot| slot.borrow().is_some()) {
        publish_observation(Observation::Cluster(cluster()));
    }
}

pub(crate) fn publish_observation(observation: Observation) {
    if let Some(client) = CLIENT.get() {
        (client.observe)(observation);
        return;
    }
    #[cfg(test)]
    if let Some(observer) = TEST_OBSERVER.with(|slot| slot.borrow().clone()) {
        observer(observation);
    }
    #[cfg(not(test))]
    let _ = observation;
}

#[derive(Clone, Copy)]
pub enum AudioControl {
    Stop,
    Start,
}

pub(crate) fn publish_audio(samples: &[f32]) {
    if let Some(client) = CLIENT.get() {
        (client.audio)(samples);
    }
}

pub(crate) fn publish_audio_control(control: AudioControl) {
    if let Some(client) = CLIENT.get() {
        (client.audio_state)(control);
    }
}

#[cfg(test)]
thread_local! {
    static TEST_OBSERVER: std::cell::RefCell<Option<std::rc::Rc<dyn Fn(Observation)>>> =
        std::cell::RefCell::default();
}

/// Gives a synthetic producer an observer on the calling test thread. Clearing it on
/// drop keeps concurrent tests and production installation independent.
#[cfg(test)]
pub(super) struct TestObserver;

#[cfg(test)]
impl TestObserver {
    pub(super) fn install(observe: impl Fn(Observation) + 'static) -> Self {
        TEST_OBSERVER.with(|slot| {
            let mut slot = slot.borrow_mut();
            assert!(slot.is_none());
            *slot = Some(std::rc::Rc::new(observe));
        });
        Self
    }
}

#[cfg(test)]
impl Drop for TestObserver {
    fn drop(&mut self) {
        TEST_OBSERVER.with(|slot| slot.borrow_mut().take());
    }
}

pub(crate) fn connection(stamp: SnapshotStamp, state: &ConnectionState) -> Connection {
    Connection {
        sequence: stamp.revision,
        generation: stamp.session_generation,
        connected: state.session_connected,
        ready: state.spirc_ready,
        local: state.is_active_device,
        resume_pending: state.resume_pending,
        credentials_rejected: state.credentials_rejected,
        id: state.device_id.clone(),
        error: state.last_error.clone(),
    }
}

pub(crate) fn playback(stamp: SnapshotStamp, state: &PlaybackObservation) -> Playback {
    Playback {
        sequence: stamp.revision,
        generation: stamp.session_generation,
        position_ms: state.position_ms.clamp(0, i64::from(u32::MAX)) as u32,
        duration_ms: state.duration_ms.clamp(0, i64::from(u32::MAX)) as u32,
        timestamp_ms: state.timestamp_ms,
        playing: state.is_playing && !state.is_paused,
        unavailable: state.track_unavailable,
        rejected: state.audio_key_refused,
        shuffle: state.shuffle,
        repeat_track: state.repeat_track,
        repeat_context: state.repeat_context,
        local: state.is_active_device,
        track: state.track_uri.clone(),
        context: state.context_uri.clone(),
    }
}

/// The result of dispatching a command. Accepted commands may still require a later
/// observation to confirm the requested playback state.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CommandError {
    Failed,
    NotConnected,
    NeedsReinitialization,
    CredentialsRejected,
    ResumeMismatch,
    ResumeBusy,
    Superseded,
}

pub(crate) use super::device_identity::set_device_id;
pub(crate) use super::session_lifecycle::authorize_streaming as authorize;

#[cfg(target_os = "macos")]
pub fn set_device_name(name: &str) {
    set_connect_device_name(name);
}

pub fn initialize() -> Result<(), CommandError> {
    initialize_player()
}

pub fn shutdown() {
    let _ = shutdown_player();
    cleanup_player();
}

pub fn forget_credentials() -> std::io::Result<()> {
    try_clear_resolved_credentials()
}

pub fn generation() -> u64 {
    SESSION_GENERATION.load(Ordering::SeqCst)
}

/// Last assigned revision, for fencing observations captured before command dispatch.
pub fn observation_revision() -> u64 {
    *SNAPSHOT_REVISION
        .lock()
        .unwrap_or_else(|error| error.into_inner())
}

pub fn reconnect() {
    let _ = force_reconnect();
}

/// Playback intent captured before sleep pauses and disconnects the local player.
#[cfg(target_os = "macos")]
pub struct SuspendedPlayback {
    generation: u64,
    intent: RecoveryIntent,
}

#[cfg(target_os = "macos")]
pub fn suspend() -> SuspendedPlayback {
    let generation = generation();
    let intent = with_engine(|engine| {
        SLEEPING.store(true, Ordering::SeqCst);
        RecoveryIntent {
            was_playing: engine.is_playing(),
            was_active: engine.connection.is_active_device,
        }
    });
    let _ = disconnect_player();
    SuspendedPlayback { generation, intent }
}

#[cfg(target_os = "macos")]
pub fn wake(interrupted: Option<SuspendedPlayback>) -> Result<(), CommandError> {
    let generation = generation();
    let intent = interrupted
        .filter(|playback| playback.generation == generation)
        .map_or_else(RecoveryIntent::capture, |playback| playback.intent);
    if reconnect_with_intent(intent) == Reconnect::NoSession {
        initialize()
    } else {
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct RepeatFlags {
    pub context: bool,
    pub track: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RepeatChange {
    Context(bool),
    Track(bool),
}

impl RepeatFlags {
    /// Spotify exposes two switches. Only send changes, with context before track.
    pub fn changes(self, target: Self) -> impl Iterator<Item = RepeatChange> {
        [
            (self.context != target.context).then_some(RepeatChange::Context(target.context)),
            (self.track != target.track).then_some(RepeatChange::Track(target.track)),
        ]
        .into_iter()
        .flatten()
    }
}

pub enum Command<'a> {
    Pause,
    Resume {
        track: &'a str,
        context: Option<&'a str>,
        position: u32,
    },
    Next,
    Previous,
    Seek(u32),
    Shuffle(bool),
    Repeat(RepeatFlags),
    Play(&'a str),
    PlayTracks(&'a [String]),
    Transfer(Option<&'a str>),
    Add(&'a str),
}

pub fn command(generation: u64, action: Command<'_>) -> Result<(), CommandError> {
    match action {
        Command::Pause => pause_playback(generation),
        Command::Resume {
            track,
            context,
            position,
        } => resume_observed(track, context, position, generation),
        Command::Next => send_spirc_command(generation, "Next", Spirc::next),
        Command::Previous => send_spirc_command(generation, "Previous", Spirc::prev),
        Command::Seek(position) => {
            send_spirc_command(generation, "Seek", |spirc| spirc.set_position_ms(position))
        }
        Command::Shuffle(enabled) => {
            send_spirc_command(generation, "Shuffle", |spirc| spirc.shuffle(enabled))
        }
        Command::Repeat(target) => set_repeat(generation, target),
        Command::Play(uri) => play_uri(generation, uri),
        Command::PlayTracks(tracks) => play_tracks(generation, tracks),
        Command::Transfer(Some(id)) => transfer_playback(generation, id),
        Command::Transfer(None) => transfer_to_local(generation),
        Command::Add(uri) => add_to_queue(generation, uri),
    }
}

fn set_repeat(generation: u64, target: RepeatFlags) -> Result<(), CommandError> {
    send_spirc_command(generation, "Repeat", |spirc| {
        let (_, track, context) = current_playback_options();
        let previous = RepeatFlags { context, track };
        for change in previous.changes(target) {
            match change {
                RepeatChange::Context(enabled) => spirc.repeat(enabled)?,
                RepeatChange::Track(enabled) => {
                    if let Err(error) = spirc.repeat_track(enabled) {
                        if previous.context != target.context {
                            let _ = spirc.repeat(previous.context);
                        }
                        return Err(error);
                    }
                }
            }
        }
        Ok(())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn repeat_preserves_both_observed_flags_and_changes_context_first() {
        let off = RepeatFlags::default();
        let context = RepeatFlags {
            context: true,
            track: false,
        };
        let track = RepeatFlags {
            context: false,
            track: true,
        };
        let both = RepeatFlags {
            context: true,
            track: true,
        };
        assert_eq!(
            context.changes(track).collect::<Vec<_>>(),
            [RepeatChange::Context(false), RepeatChange::Track(true)]
        );
        assert_eq!(
            both.changes(off).collect::<Vec<_>>(),
            [RepeatChange::Context(false), RepeatChange::Track(false)]
        );
        assert!(track.changes(track).next().is_none());
    }
}
