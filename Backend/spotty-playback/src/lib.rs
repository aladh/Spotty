//! Native Spotify playback and Connect bridge for Spotty.
//!
//! The crate intentionally retains process-wide ownership: the macOS application creates one
//! playback engine for one account. Modules separate the synchronization, FFI, lifecycle,
//! Connect, queue, transport, and player-event-pump responsibilities without changing that
//! runtime contract.

mod connect;
mod engine_resources;
mod ffi;
mod lifecycle_serialization;
mod player_control;
mod player_event_pump;
mod proxy_sink;
mod queue;
mod runtime;
mod session_lifecycle;
mod spirc_command_error;
mod state;
mod transport;

pub(crate) use connect::*;
pub(crate) use engine_resources::*;
pub(crate) use ffi::*;
pub(crate) use lifecycle_serialization::*;
pub(crate) use player_control::*;
pub(crate) use player_event_pump::*;
pub(crate) use proxy_sink::mk_proxy_sink;
pub(crate) use queue::*;
pub(crate) use runtime::*;
pub(crate) use session_lifecycle::*;
pub(crate) use spirc_command_error::*;
pub(crate) use state::*;
pub(crate) use transport::*;

pub(crate) use futures_util::StreamExt;
pub(crate) use librespot_connect::{
    ConnectConfig, LoadRequest, LoadRequestOptions, PlayingTrack, Spirc,
};
pub(crate) use librespot_core::cache::Cache;
pub(crate) use librespot_core::config::DeviceType;
pub(crate) use librespot_core::session::Session;
pub(crate) use librespot_core::SessionConfig;
pub(crate) use librespot_core::SpotifyUri;
pub(crate) use librespot_playback::config::{AudioFormat, Bitrate, PlayerConfig};
pub(crate) use librespot_playback::mixer::softmixer::SoftMixer;
pub(crate) use librespot_playback::mixer::{Mixer, MixerConfig, NoOpVolume};
pub(crate) use librespot_playback::player::{Player, PlayerEvent};
pub(crate) use librespot_protocol::connect::{Cluster, ClusterUpdate, MemberType, PutStateRequest};
pub(crate) use librespot_protocol::player::{PlayerState, ProvidedTrack};
pub(crate) use log::debug;
pub(crate) use once_cell::sync::Lazy;
pub(crate) use std::ffi::{c_char, CStr, CString};
pub(crate) use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
pub(crate) use std::sync::{Arc, Condvar, Mutex};
pub(crate) use std::time::{Duration, SystemTime, UNIX_EPOCH};
pub(crate) use tokio::runtime::Runtime;
pub(crate) use tokio::sync::mpsc;
pub(crate) use tokio::task::JoinHandle;

#[cfg(test)]
mod connect_cluster_apply_tests;
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
