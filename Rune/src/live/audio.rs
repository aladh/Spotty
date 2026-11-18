use crate::playback::client::AudioControl;
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use rtrb::{Consumer, Producer, PushError, RingBuffer};
use std::{
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

struct Frame {
    generation: u64,
    samples: [f32; 2],
}

fn discard_retired_frames(read: &mut Consumer<Frame>, generation: u64) {
    let retired = |frame: &Frame| {
        let age = generation.wrapping_sub(frame.generation);
        age > 0 && age < (1 << 63)
    };
    if read.peek().is_ok_and(retired)
        && let Ok(chunk) = read.read_chunk(read.slots())
    {
        let (first, second) = chunk.as_slices();
        // The writer serializes insertion, so retired epochs occupy one ordered prefix.
        let mut discard = first.partition_point(retired);
        if discard == first.len() {
            discard += second.partition_point(retired);
        }
        chunk.commit(discard);
    }
}

fn take_current_frame(read: &mut Consumer<Frame>, generation: u64) -> Option<[f32; 2]> {
    (read.peek().ok()?.generation == generation)
        .then(|| read.pop().ok().map(|frame| frame.samples))
        .flatten()
}

#[derive(Default)]
pub struct Audio {
    write: Mutex<Option<Producer<Frame>>>,
    worker: Mutex<Option<JoinHandle<()>>>,
    stopping: AtomicBool,
    generation: AtomicU64,
    playing: AtomicBool,
    available: AtomicBool,
}

impl Audio {
    pub fn open() -> Arc<Self> {
        let audio = Arc::new(Self::default());
        let system = Arc::clone(&audio);
        if let Ok(worker) = thread::Builder::new()
            .name("Spotty audio device".into())
            .spawn(move || system.monitor())
        {
            *audio
                .worker
                .lock()
                .unwrap_or_else(|error| error.into_inner()) = Some(worker);
        }
        audio
    }

    pub fn shutdown(&self) {
        self.stopping.store(true, Ordering::Release);
        self.available.store(false, Ordering::Release);
        if let Some(worker) = self
            .worker
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .take()
        {
            worker.thread().unpark();
            let _ = worker.join();
        }
    }

    fn monitor(self: Arc<Self>) {
        let host = cpal::default_host();
        let mut output: Option<ActiveOutput> = None;
        while !self.stopping.load(Ordering::Acquire) {
            let requested = host.default_output_device().and_then(|device| {
                let format = device.default_output_config().ok()?;
                Some((device, format))
            });
            let current = output.as_ref().zip(requested.as_ref()).is_some_and(
                |(active, (device, format))| {
                    !active.failed.load(Ordering::Acquire)
                        && same_device(&active.device, device)
                        && active.format.channels() == format.channels()
                        && active.format.sample_rate() == format.sample_rate()
                        && active.format.sample_format() == format.sample_format()
                },
            );
            if !current {
                self.detach();
                drop(output.take());
                if let Some((device, format)) = requested {
                    let (write, read) = RingBuffer::new(88_200);
                    let failed = Arc::new(AtomicBool::new(false));
                    if let Ok(stream) = self.output(read, &device, &format, Arc::clone(&failed))
                        && stream.play().is_ok()
                    {
                        self.attach(write);
                        output = Some(ActiveOutput {
                            device,
                            format,
                            failed,
                            _stream: stream,
                        });
                    }
                }
            }
            thread::park_timeout(Duration::from_secs(1));
        }
        self.detach();
    }

    fn detach(&self) {
        self.available.store(false, Ordering::Release);
        self.generation.fetch_add(1, Ordering::AcqRel);
        self.write
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .take();
    }

    fn attach(&self, write: Producer<Frame>) {
        self.write
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .replace(write);
        self.available.store(true, Ordering::Release);
    }

    pub fn available(&self) -> bool {
        self.available.load(Ordering::Acquire)
    }

    pub fn control(&self, command: AudioControl) {
        match command {
            AudioControl::Start => self.playing.store(true, Ordering::Release),
            AudioControl::Stop => {
                self.playing.store(false, Ordering::Release);
                self.generation.fetch_add(1, Ordering::AcqRel);
            }
        }
    }

    pub fn write(&self, samples: &[f32]) {
        if !self.available() || !samples.len().is_multiple_of(2) {
            return;
        }
        // Capture the epoch before waiting for the writer. A cleared packet cannot
        // become current simply because a new ring was installed while it waited.
        let generation = self.generation.load(Ordering::Acquire);
        let Ok(mut writer) = self.write.lock() else {
            return;
        };
        let Some(producer) = writer.as_mut() else {
            return;
        };
        let deadline = Instant::now() + Duration::from_millis(500);
        for stereo in samples.chunks_exact(2) {
            let mut frame = Frame {
                generation,
                samples: [stereo[0], stereo[1]],
            };
            loop {
                if self.generation.load(Ordering::Acquire) != generation
                    || !self.playing.load(Ordering::Acquire)
                    || !self.available()
                {
                    return;
                }
                match producer.push(frame) {
                    Ok(()) => break,
                    Err(PushError::Full(pending)) => {
                        if Instant::now() >= deadline {
                            return;
                        }
                        frame = pending;
                        std::thread::sleep(Duration::from_millis(1));
                    }
                }
            }
        }
    }

    fn output(
        self: &Arc<Self>,
        read: Consumer<Frame>,
        device: &cpal::Device,
        format: &cpal::SupportedStreamConfig,
        failed: Arc<AtomicBool>,
    ) -> Result<cpal::Stream, String> {
        // Use the system-selected rate. Changing a Mac device's nominal rate here
        // would affect every other app sharing the output.
        let config = format.config();
        match format.sample_format() {
            cpal::SampleFormat::F32 => self.stream::<f32>(read, device, config, failed),
            cpal::SampleFormat::F64 => self.stream::<f64>(read, device, config, failed),
            cpal::SampleFormat::I8 => self.stream::<i8>(read, device, config, failed),
            cpal::SampleFormat::U8 => self.stream::<u8>(read, device, config, failed),
            cpal::SampleFormat::I16 => self.stream::<i16>(read, device, config, failed),
            cpal::SampleFormat::U16 => self.stream::<u16>(read, device, config, failed),
            cpal::SampleFormat::I24 => self.stream::<cpal::I24>(read, device, config, failed),
            cpal::SampleFormat::I32 => self.stream::<i32>(read, device, config, failed),
            cpal::SampleFormat::U32 => self.stream::<u32>(read, device, config, failed),
            cpal::SampleFormat::I64 => self.stream::<i64>(read, device, config, failed),
            cpal::SampleFormat::U64 => self.stream::<u64>(read, device, config, failed),
            _ => Err("Unsupported audio sample format".into()),
        }
    }

    fn stream<T>(
        self: &Arc<Self>,
        mut read: Consumer<Frame>,
        device: &cpal::Device,
        config: cpal::StreamConfig,
        failed: Arc<AtomicBool>,
    ) -> Result<cpal::Stream, String>
    where
        T: cpal::SizedSample + cpal::FromSample<f32>,
    {
        let mut position = 0.0;
        let mut samples = None;
        let mut next = None;
        let mut last_generation = 0;
        let channels = config.channels.max(1) as usize;
        let step = 44_100.0 / f64::from(config.sample_rate.0);
        let render = Arc::clone(self);
        let monitor = thread::current();
        device
            .build_output_stream(
                &config,
                move |buffer: &mut [T], _| {
                    let generation = render.generation.load(Ordering::Acquire);
                    let playing = render.playing.load(Ordering::Acquire);
                    if generation != last_generation {
                        samples = None;
                        next = None;
                        position = 0.0;
                        last_generation = generation;
                    }
                    discard_retired_frames(&mut read, generation);
                    let mut take = || take_current_frame(&mut read, generation);
                    for frame in buffer.chunks_mut(channels) {
                        if playing && samples.is_none() {
                            samples = take();
                        }
                        let pair = if playing {
                            if next.is_none() {
                                next = take();
                            }
                            match (samples, next) {
                                (Some(a), Some(b)) => [
                                    a[0] + (b[0] - a[0]) * position as f32,
                                    a[1] + (b[1] - a[1]) * position as f32,
                                ],
                                (Some(a), None) => a,
                                _ => [0.0, 0.0],
                            }
                        } else {
                            [0.0, 0.0]
                        };
                        if channels == 1 {
                            frame[0] = T::from_sample((pair[0] + pair[1]) * 0.5);
                        } else {
                            for (index, output) in frame.iter_mut().enumerate() {
                                *output =
                                    T::from_sample(pair.get(index).copied().unwrap_or_default());
                            }
                        }
                        if samples.is_some() {
                            position += step;
                            while position >= 1.0 {
                                samples = next.take().or_else(&mut take);
                                position -= 1.0;
                            }
                        }
                    }
                    // An epoch can end while this callback holds decoded samples.
                    if render.generation.load(Ordering::Acquire) != generation {
                        buffer.fill(T::EQUILIBRIUM);
                    }
                },
                move |_| {
                    // A delayed error from a retired stream can only flag that stream.
                    failed.store(true, Ordering::Release);
                    monitor.unpark();
                },
                None,
            )
            .map_err(|e| e.to_string())
    }
}

struct ActiveOutput {
    device: cpal::Device,
    format: cpal::SupportedStreamConfig,
    failed: Arc<AtomicBool>,
    _stream: cpal::Stream,
}

#[cfg(target_os = "macos")]
fn same_device(left: &cpal::Device, right: &cpal::Device) -> bool {
    // CoreAudio device equality compares its AudioDeviceID, including namesakes.
    use cpal::platform::DeviceInner::CoreAudio;
    matches!((left.as_inner(), right.as_inner()), (CoreAudio(a), CoreAudio(b)) if a == b)
}

#[cfg(not(target_os = "macos"))]
fn same_device(left: &cpal::Device, right: &cpal::Device) -> bool {
    left.name()
        .ok()
        .zip(right.name().ok())
        .is_some_and(|(left, right)| left == right)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn replaced_output_rejects_old_packets_and_resumes_on_the_new_ring() {
        let audio = Audio::default();
        let (old, mut retired) = RingBuffer::new(4);
        audio.attach(old);
        audio.control(AudioControl::Start);
        audio.write(&[0.1, 0.2]);
        let first = retired.pop().unwrap();

        audio.detach();
        audio.write(&[0.3, 0.4]);
        let (new, mut current) = RingBuffer::new(4);
        audio.attach(new);
        audio.write(&[0.4, 0.5, 0.6]); // A malformed packet cannot split a stereo frame.
        assert!(current.pop().is_err());
        audio.write(&[0.7, 0.8]);
        assert!(retired.pop().is_err());
        let second = current.pop().unwrap();
        assert_ne!(first.generation, second.generation);
        assert_eq!(second.samples, [0.7, 0.8]);

        audio.control(AudioControl::Stop);
        audio.write(&[0.9, 1.0]);
        assert!(current.pop().is_err());
    }

    #[test]
    fn stopped_output_retires_queued_frames_and_rejects_late_pcm_until_restart() {
        let audio = Audio::default();
        let (producer, mut consumer) = RingBuffer::new(2);
        audio.attach(producer);
        audio.control(AudioControl::Start);
        audio.write(&[0.1, 0.2, 0.3, 0.4]);
        assert_eq!(consumer.slots(), 2);

        audio.control(AudioControl::Stop);
        let stopped_generation = audio.generation.load(Ordering::Acquire);
        discard_retired_frames(&mut consumer, stopped_generation);
        assert_eq!(consumer.slots(), 0);
        audio.write(&[0.5, 0.6]);
        assert!(consumer.pop().is_err());

        audio.control(AudioControl::Start);
        audio.write(&[0.7, 0.8]);
        assert_eq!(consumer.pop().unwrap().samples, [0.7, 0.8]);
    }

    #[test]
    fn a_wrapped_audio_ring_retires_old_frames_and_keeps_a_newer_epoch() {
        let (mut write, mut read) = RingBuffer::new(4);
        let frame = |generation, sample| Frame {
            generation,
            samples: [sample, sample],
        };
        for _ in 0..3 {
            assert!(write.push(frame(5, 0.0)).is_ok());
            assert!(read.pop().is_ok());
        }
        assert!(write.push(frame(6, 0.1)).is_ok());
        assert!(write.push(frame(6, 0.2)).is_ok());
        assert!(write.push(frame(7, 0.3)).is_ok());
        assert!(write.push(frame(8, 0.4)).is_ok());
        discard_retired_frames(&mut read, 7);
        assert_eq!(read.slots(), 2);
        assert_eq!(take_current_frame(&mut read, 7), Some([0.3, 0.3]));
        assert_eq!(take_current_frame(&mut read, 7), None);
        assert_eq!(take_current_frame(&mut read, 8), Some([0.4, 0.4]));
    }
}
