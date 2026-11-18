//! Proxy Audio Sink
//!
//! Delivers decoded interleaved stereo PCM at 44.1 kHz to the installed renderer.

use super::client::{self, AudioControl};
use librespot_playback::audio_backend::{Sink, SinkError, SinkResult};
use librespot_playback::config::AudioFormat;
use librespot_playback::convert::Converter;
use librespot_playback::decoder::AudioPacket;
use log::debug;
use std::sync::atomic::Ordering;

/// The single PCM sink for the librespot player.
pub struct ProxySink;

impl ProxySink {
    /// Reject further PCM and retire the queued software frames until the next Start.
    /// This takes effect without waiting for the player to process a pause or stop.
    pub fn stop_rendering() {
        client::publish_audio_control(AudioControl::Stop);
    }
}

impl Sink for ProxySink {
    fn start(&mut self) -> SinkResult<()> {
        debug!("ProxySink: Start");
        if !super::SLEEPING.load(Ordering::SeqCst) {
            client::publish_audio_control(AudioControl::Start);
            // Suspend may have retired this player's output while Start was in flight.
            // Recheck before returning control to the same thread that writes PCM.
            if super::SLEEPING.load(Ordering::SeqCst) {
                Self::stop_rendering();
            }
        }
        Ok(())
    }

    fn stop(&mut self) -> SinkResult<()> {
        debug!("ProxySink: Stop");
        Self::stop_rendering();
        Ok(())
    }

    fn write(&mut self, packet: AudioPacket, converter: &mut Converter) -> SinkResult<()> {
        let samples = packet
            .samples()
            .map_err(|e| SinkError::OnWrite(format!("Failed to get samples: {}", e)))?;

        let samples_f32: Vec<f32> = converter.f64_to_f32(samples);

        client::publish_audio(&samples_f32);
        Ok(())
    }
}

/// Factory function to create a ProxySink
pub fn mk_proxy_sink(_device: Option<String>, _format: AudioFormat) -> Box<dyn Sink> {
    debug!("ProxySink: Created new instance");
    Box::new(ProxySink)
}
