//! Spotify playback, Connect and session recovery for the Rune application.
//! The application owns one local player and publishes typed observations to its session worker.

pub(crate) mod client;
use client::CommandError;
mod connect;
mod device_identity;
mod engine_resources;
mod lifecycle_serialization;
mod observed_resume;
mod player_control;
mod player_event_pump;
mod proxy_sink;
mod queue;
mod recovery;
mod runtime;
mod selection_load_policy;
mod session_lifecycle;
mod spirc_command_error;
mod spotify_uri;
mod state;
mod transport;

use connect::*;
use device_identity::*;
use engine_resources::*;
use lifecycle_serialization::*;
use observed_resume::*;
use player_control::*;
use player_event_pump::*;
use proxy_sink::mk_proxy_sink;
use queue::*;
use recovery::*;
use runtime::*;
use session_lifecycle::*;
use spirc_command_error::*;
use spotify_uri::*;
use state::*;
use transport::*;

use futures_util::StreamExt;
use librespot_connect::{ConnectConfig, LoadRequest, LoadRequestOptions, PlayingTrack, Spirc};
use librespot_core::SessionConfig;
use librespot_core::SpotifyUri;
use librespot_core::cache::Cache;
use librespot_core::config::DeviceType;
use librespot_core::session::Session;
use librespot_playback::config::{AudioFormat, Bitrate, PlayerConfig};
use librespot_playback::mixer::softmixer::SoftMixer;
use librespot_playback::mixer::{Mixer, MixerConfig, NoOpVolume};
use librespot_playback::player::{PlayerEvent, PlayerObserver};
use librespot_protocol::connect::{Cluster, ClusterUpdate, MemberType, PutStateRequest};
use librespot_protocol::player::{PlayerState, ProvidedTrack};
use log::debug;
use once_cell::sync::Lazy;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::runtime::Runtime;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

#[cfg(test)]
mod audio_cache_evaluation;
#[cfg(test)]
mod connect_cluster_apply_tests;
#[cfg(test)]
mod lifecycle_measurements;
#[cfg(test)]
mod lifecycle_serialization_tests;
#[cfg(test)]
mod queue_snapshot_tests;
#[cfg(test)]
mod queue_tests;
#[cfg(test)]
mod retained_lifecycle_tests;
#[cfg(test)]
mod spirc_command_error_tests;
#[cfg(test)]
mod tests;

#[cfg(test)]
struct ObservationFixture {
    _guard: std::sync::MutexGuard<'static, ()>,
    generation: u64,
    connection: ConnectionState,
    observed_resume: ObservedResumeState,
    playing: bool,
    stamp: PlayingEventStamp,
    context: Option<String>,
    options: (bool, bool, bool),
}

#[cfg(test)]
impl ObservationFixture {
    fn new() -> Self {
        let guard = lock_lifecycle_test_globals();
        Self {
            _guard: guard,
            generation: SESSION_GENERATION.load(Ordering::SeqCst),
            connection: with_connection(|connection| connection.clone()),
            observed_resume: with_engine(|engine| std::mem::take(&mut engine.observed_resume)),
            playing: engine_is_playing(),
            stamp: playing_event_stamp(),
            context: CURRENT_CONTEXT_URI.lock().unwrap().clone(),
            options: current_playback_options(),
        }
    }
}

#[cfg(test)]
impl Drop for ObservationFixture {
    fn drop(&mut self) {
        if SESSION_GENERATION.load(Ordering::SeqCst) != self.generation {
            set_session_generation_for_test(self.generation);
        }
        with_connection(|connection| *connection = std::mem::take(&mut self.connection));
        with_engine(|engine| engine.observed_resume = std::mem::take(&mut self.observed_resume));
        replace_playing_event_stamp_for_test(self.stamp);
        set_engine_playing_for_test(self.playing);
        *CURRENT_CONTEXT_URI
            .lock()
            .unwrap_or_else(|error| error.into_inner()) = self.context.take();
        let (shuffle, track, context) = self.options;
        update_playback_options(shuffle, track, context);
    }
}
