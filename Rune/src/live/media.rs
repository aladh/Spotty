use super::{Artwork, Input, Live};
use crate::model::{Snapshot, Stamp};
use block2::RcBlock;
use objc2::{AnyThread, rc::Retained, runtime::AnyObject};
use objc2_app_kit::NSImage;
use objc2_core_foundation::{CFData, CGSize};
use objc2_core_graphics::{
    CGBitmapInfo, CGColorRenderingIntent, CGColorSpace, CGDataProvider, CGImage, CGImageAlphaInfo,
};
use objc2_foundation::{NSDictionary, NSNumber, NSString};
use objc2_media_player::*;
use std::{
    ptr::NonNull,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

#[derive(Clone, Copy)]
pub(super) enum Action {
    Toggle,
    Play,
    Pause,
    Next,
    Previous,
    Seek,
}

pub(super) struct MediaInput {
    pub stamp: Stamp,
    pub track: String,
    pub action: Action,
    pub seconds: Option<f64>,
}

struct Admission {
    stamp: Stamp,
    track: String,
    playing: bool,
    toggle: bool,
    skip: bool,
    seek: bool,
}

impl Admission {
    fn allows(&self, action: Action) -> bool {
        match action {
            Action::Toggle => self.toggle,
            Action::Play => self.toggle && !self.playing,
            Action::Pause => self.toggle && self.playing,
            Action::Next | Action::Previous => self.skip,
            Action::Seek => self.seek,
        }
    }
}

#[derive(PartialEq)]
struct Metadata {
    account: u64,
    track: String,
    title: String,
    artist: String,
    playing: bool,
    duration: f64,
    cover: Option<String>,
}

pub struct Media {
    center: Retained<MPNowPlayingInfoCenter>,
    handlers: Vec<(Action, Retained<MPRemoteCommand>, Retained<AnyObject>)>,
    gate: Arc<Mutex<Option<Admission>>>,
    last: Option<Metadata>,
    artwork: Option<(u64, String, Retained<MPMediaItemArtwork>)>,
    next_progress: Instant,
    last_progress: Option<(Instant, f64)>,
}

impl Media {
    pub fn new() -> Self {
        Self {
            center: unsafe { MPNowPlayingInfoCenter::defaultCenter() },
            handlers: Vec::new(),
            gate: Arc::default(),
            last: None,
            artwork: None,
            next_progress: Instant::now(),
            last_progress: None,
        }
    }

    fn attach(&mut self, runtime: &Live) {
        let center = unsafe { MPRemoteCommandCenter::sharedCommandCenter() };
        for (action, command) in unsafe {
            [
                (Action::Toggle, center.togglePlayPauseCommand()),
                (Action::Play, center.playCommand()),
                (Action::Pause, center.pauseCommand()),
                (Action::Previous, center.previousTrackCommand()),
                (Action::Next, center.nextTrackCommand()),
                (
                    Action::Seek,
                    Retained::into_super(center.changePlaybackPositionCommand()),
                ),
            ]
        } {
            let gate = Arc::clone(&self.gate);
            let sender = runtime.send.clone();
            let handler = RcBlock::new(move |event: NonNull<MPRemoteCommandEvent>| {
                let Ok(current) = gate.lock() else {
                    return MPRemoteCommandHandlerStatus::CommandFailed;
                };
                let Some(permit) = current.as_ref().filter(|p| p.allows(action)) else {
                    return MPRemoteCommandHandlerStatus::CommandFailed;
                };
                let seconds = if matches!(action, Action::Seek) {
                    let event: &AnyObject = unsafe { event.as_ref() };
                    let Some(seek) = event.downcast_ref::<MPChangePlaybackPositionCommandEvent>()
                    else {
                        return MPRemoteCommandHandlerStatus::CommandFailed;
                    };
                    let time = unsafe { seek.positionTime() };
                    if !time.is_finite() {
                        return MPRemoteCommandHandlerStatus::CommandFailed;
                    }
                    Some(time)
                } else {
                    None
                };
                let input = MediaInput {
                    action,
                    stamp: permit.stamp,
                    track: permit.track.clone(),
                    seconds,
                };
                if sender.send(Input::Media(input)).is_ok() {
                    MPRemoteCommandHandlerStatus::Success
                } else {
                    MPRemoteCommandHandlerStatus::CommandFailed
                }
            });
            let target = unsafe { command.addTargetWithHandler(&handler) };
            self.handlers.push((action, command, target));
        }
    }

    pub fn update(&mut self, runtime: &Live, snapshot: &Snapshot) {
        let player = &snapshot.playback;
        if snapshot.phase != "ready" || !snapshot.catalog_ready || player.uri.is_empty() {
            self.stop();
            return;
        }
        if self.handlers.is_empty() {
            self.attach(runtime);
        }
        let permit = Admission {
            stamp: snapshot.stamp,
            track: player.uri.clone(),
            playing: player.playing,
            toggle: player.can_toggle,
            skip: player.can_skip,
            seek: player.can_start && player.duration > 0.0,
        };
        for (action, command, _) in &self.handlers {
            unsafe { command.setEnabled(permit.allows(*action)) };
        }
        *self.gate.lock().unwrap_or_else(|e| e.into_inner()) = Some(permit);
        let next = Metadata {
            account: snapshot.stamp.account,
            track: player.uri.clone(),
            title: player.title.clone(),
            artist: player.artist.clone(),
            playing: player.playing,
            duration: player.duration,
            cover: player.artwork.clone(),
        };
        let artwork_current = self.artwork.as_ref().is_some_and(|(account, url, _)| {
            *account == next.account && Some(url) == next.cover.as_ref()
        });
        if !artwork_current {
            self.artwork = None;
            let changed = self
                .last
                .as_ref()
                .is_none_or(|last| last.account != next.account || last.cover != next.cover);
            if changed && let Some(url) = next.cover.as_ref() {
                runtime.artwork(next.account, url.clone());
            }
        }
        let now = Instant::now();
        let discontinuity = self.last_progress.is_some_and(|(published, position)| {
            let mut expected = position;
            if next.playing {
                expected += now.duration_since(published).as_secs_f64();
            }
            if next.duration > 0.0 {
                expected = expected.min(next.duration);
            }
            (player.position - expected).abs() > 0.25
        });
        if self.last.as_ref() == Some(&next) && now < self.next_progress && !discontinuity {
            return;
        }
        self.next_progress = now + Duration::from_secs(1);
        self.last_progress = Some((now, player.position));
        let title = NSString::from_str(&next.title);
        let artist = NSString::from_str(&next.artist);
        let duration = NSNumber::new_f64(next.duration);
        let position = NSNumber::new_f64(player.position);
        let rate = NSNumber::new_f64(if next.playing { 1.0 } else { 0.0 });
        // The exported MediaPlayer keys are immutable NSString constants.
        let mut keys = unsafe {
            vec![
                MPMediaItemPropertyTitle,
                MPMediaItemPropertyArtist,
                MPMediaItemPropertyPlaybackDuration,
                MPNowPlayingInfoPropertyElapsedPlaybackTime,
                MPNowPlayingInfoPropertyPlaybackRate,
            ]
        };
        let mut values: Vec<&AnyObject> = vec![&title, &artist, &duration, &position, &rate];
        if let Some((_, _, art)) = &self.artwork {
            keys.push(unsafe { MPMediaItemPropertyArtwork });
            values.push(art);
        }
        let info = NSDictionary::from_slices(&keys, &values);
        unsafe {
            self.center.setNowPlayingInfo(Some(&info));
            self.center.setPlaybackState(if next.playing {
                MPNowPlayingPlaybackState::Playing
            } else {
                MPNowPlayingPlaybackState::Paused
            });
        }
        self.last = Some(next);
    }

    pub fn artwork(&mut self, snapshot: &Snapshot, url: &str, art: &Artwork) {
        if snapshot.phase != "ready" || snapshot.playback.artwork.as_deref() != Some(url) {
            return;
        }
        let Some(image) = native_artwork(art) else {
            return;
        };
        self.artwork = Some((snapshot.stamp.account, url.to_owned(), image));
        self.next_progress = Instant::now();
    }

    pub fn stop(&mut self) {
        if self.handlers.is_empty() && self.last.is_none() {
            return;
        }
        *self.gate.lock().unwrap_or_else(|e| e.into_inner()) = None;
        for (_, command, target) in self.handlers.drain(..) {
            unsafe {
                command.setEnabled(false);
                command.removeTarget(Some(&target));
            }
        }
        self.gate = Arc::default(); // Callbacks already queued for the old account remain fenced.
        self.last = None;
        self.last_progress = None;
        self.artwork = None;
        unsafe {
            self.center
                .setPlaybackState(MPNowPlayingPlaybackState::Stopped);
            self.center.setNowPlayingInfo(None);
        }
    }
}

// The host can request artwork off the UI thread. Share immutable CGImage pixels;
// each request receives its own NSImage, with no file or network access.
fn native_artwork(art: &Artwork) -> Option<Retained<MPMediaItemArtwork>> {
    let width = art.width as usize;
    let height = art.height as usize;
    if width.checked_mul(height)?.checked_mul(4)? != art.rgba.len() {
        return None;
    }
    let color = CGColorSpace::new_device_rgb()?;
    let provider = CGDataProvider::with_cf_data(Some(&CFData::from_bytes(&art.rgba)))?;
    let pixels = unsafe {
        CGImage::new(
            width,
            height,
            8,
            32,
            width * 4,
            Some(&color),
            CGBitmapInfo(CGImageAlphaInfo::Last.0),
            Some(&provider),
            std::ptr::null(),
            true,
            CGColorRenderingIntent::RenderingIntentDefault,
        )?
    };
    let size = CGSize::new(width as f64, height as f64);
    let request = RcBlock::new(move |_: CGSize| {
        let image = NSImage::initWithCGImage_size(NSImage::alloc(), &pixels, size);
        // MediaPlayer's block returns a non-owning Objective-C object.
        unsafe { NonNull::new_unchecked(Retained::autorelease_ptr(image)) }
    });
    Some(unsafe {
        MPMediaItemArtwork::initWithBoundsSize_requestHandler(
            MPMediaItemArtwork::alloc(),
            size,
            &request,
        )
    })
}
