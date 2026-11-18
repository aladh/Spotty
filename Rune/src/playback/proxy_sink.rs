//! Proxy Audio Sink
//!
//! Delivers decoded interleaved stereo PCM at 44.1 kHz to the installed renderer.

use super::client::{self, AudioControl};
use librespot_playback::audio_backend::{Sink, SinkError, SinkResult};
use librespot_playback::config::AudioFormat;
use librespot_playback::convert::Converter;
use librespot_playback::decoder::AudioPacket;
use log::debug;

/// The single PCM sink for the librespot player.
pub struct ProxySink;

impl ProxySink {
    /// Flush the renderer buffer synchronously.
    #[cfg(target_os = "macos")]
    pub fn clear_buffer() {
        debug!("ProxySink: Sending clear command");
        client::publish_audio_control(AudioControl::Clear);
    }

    /// Tell the renderer that playback has ended because the Player is going away.
    ///
    /// `Sink::stop` only runs when librespot stops the sink itself. Dropping the Player
    /// during a rebuild does not do that, so without this the renderer keeps believing it
    /// is rendering for a Player that no longer exists — and the next `Sink::start` finds
    /// it already rendering and skips resetting its real-time throttle.
    pub fn notify_player_gone() {
        debug!("ProxySink: Player torn down, sending stop");
        client::publish_audio_control(AudioControl::Stop);
    }
}

impl Sink for ProxySink {
    fn start(&mut self) -> SinkResult<()> {
        debug!("ProxySink: Start");
        client::publish_audio_control(AudioControl::Start);
        Ok(())
    }

    fn stop(&mut self) -> SinkResult<()> {
        debug!("ProxySink: Stop");
        client::publish_audio_control(AudioControl::Stop);
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
