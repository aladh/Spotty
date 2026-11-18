//! A command stays pending until a new engine observation matches its requested change.

use super::{Intent, Owner, Playback, engine, upcoming};
use std::{
    collections::HashMap,
    sync::{
        Arc, OnceLock,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};

const DISPATCH_TIMEOUT: Duration = Duration::from_secs(25);
const CONFIRMATION_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Default)]
pub(super) struct Dispatch {
    started: OnceLock<(u64, Instant)>,
    retired: AtomicBool,
}

impl Dispatch {
    /// Called after the local lane or remote request has passed its final admission check.
    pub(super) fn begin(&self) -> bool {
        if self.retired.load(Ordering::Acquire) {
            return false;
        }
        self.started
            .get_or_init(|| (engine::observation_revision(), Instant::now()));
        !self.retired.load(Ordering::Acquire)
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub(super) enum Occurrence {
    Id(String),
    Uri(String),
}

impl Occurrence {
    pub(super) fn of(track: &engine::QueueTrack) -> Self {
        if track.uid.is_empty() {
            Self::Uri(track.uri.clone())
        } else {
            Self::Id(track.uid.clone())
        }
    }
}

#[derive(Clone, PartialEq, Eq)]
pub(super) struct ResumeTarget {
    pub(super) track: String,
    pub(super) context: String,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum Match {
    Awaiting,
    Confirmed,
    Rejected,
    Superseded,
}

pub(super) struct Pending {
    pub(super) dispatch: Arc<Dispatch>,
    intent: Intent,
    baseline: Playback,
    owner: Owner,
    created: Instant,
    acknowledged: Option<Instant>,
    matched: Match,
    added: Option<HashMap<String, usize>>,
}

impl Pending {
    pub(super) fn new(
        intent: Intent,
        baseline: &Playback,
        owner: Owner,
        queue: Option<&engine::Queue>,
    ) -> Self {
        let added = match (&intent, queue) {
            (Intent::Add(uris), Some(queue)) => {
                let mut expected = HashMap::new();
                for uri in uris {
                    *expected.entry(uri.clone()).or_default() += 1;
                }
                for (_, row) in upcoming(queue) {
                    if row.provider == "queue"
                        && let Some(count) = expected.get_mut(&row.uri)
                    {
                        *count += 1;
                    }
                }
                Some(expected)
            }
            _ => None,
        };
        Self {
            dispatch: Arc::default(),
            intent,
            baseline: baseline.clone(),
            owner,
            created: Instant::now(),
            acknowledged: None,
            matched: Match::Awaiting,
            added,
        }
    }

    pub(super) fn expired(&self) -> bool {
        if let Some(acknowledged) = self.acknowledged {
            acknowledged.elapsed() >= CONFIRMATION_TIMEOUT
        } else {
            self.dispatch.started.get().is_none() && self.created.elapsed() >= DISPATCH_TIMEOUT
        }
    }

    /// The send permit covers the whole operation, including a multi-request mutation.
    /// Evidence can arrive first, but it cannot reopen the lane until the sender settles.
    pub(super) fn record(&mut self, outcome: Match) -> bool {
        if self.matched == Match::Awaiting {
            self.matched = outcome;
        }
        self.acknowledged.is_some() && self.matched != Match::Awaiting
    }

    pub(super) fn acknowledge(&mut self) -> bool {
        self.acknowledged = Some(Instant::now());
        self.send_only() || self.matched != Match::Awaiting
    }

    pub(super) fn observed(&self) -> bool {
        self.matched == Match::Confirmed
    }

    pub(super) fn is_queue(&self) -> bool {
        matches!(self.intent, Intent::Add(_) | Intent::Replace { .. })
    }

    pub(super) fn needs_queue_evidence(&self) -> bool {
        self.added.is_some() || matches!(self.intent, Intent::Replace { .. })
    }

    pub(super) fn send_only(&self) -> bool {
        self.is_queue() && !self.needs_queue_evidence()
    }

    pub(super) fn resume_target(&self) -> Option<ResumeTarget> {
        match &self.intent {
            Intent::Toggle {
                playing: false,
                track,
                context,
                ..
            } => Some(ResumeTarget {
                track: track.clone(),
                context: context.clone(),
            }),
            _ => None,
        }
    }

    pub(super) fn is_selection(&self) -> bool {
        matches!(self.intent, Intent::Play(_) | Intent::PlayTracks(_))
    }

    fn new_observation(&self, sequence: u64) -> Option<Duration> {
        let (baseline, dispatched) = self.dispatch.started.get()?;
        (sequence > *baseline).then(|| dispatched.elapsed())
    }

    pub(super) fn owner_without_playback(&self, sequence: u64, active: Option<&str>) -> Match {
        if self.new_observation(sequence).is_some()
            && self.baseline.uri.is_empty()
            && matches!(&self.intent, Intent::Transfer { to, .. } if active == Some(to.as_str()))
        {
            Match::Confirmed
        } else {
            Match::Awaiting
        }
    }

    pub(super) fn playback(
        &self,
        incoming: &engine::Playback,
        owner: &Owner,
        active: Option<&str>,
        protocol: bool,
    ) -> Match {
        let Some(elapsed) = self.new_observation(incoming.sequence) else {
            return Match::Awaiting;
        };
        let same_track = self.baseline.uri == incoming.track;
        let same_context = incoming.context.as_deref().unwrap_or_default() == self.baseline.context;
        if let Intent::Transfer { to, local } = &self.intent {
            let matches_role = protocol && active == Some(to.as_str()) && incoming.local == *local;
            let same_playback = same_track
                && same_context
                && self.baseline.playing == incoming.playing
                && !incoming.unavailable
                && near_position(incoming, self.baseline.position, elapsed);
            return if matches_role && (same_playback || self.baseline.uri.is_empty()) {
                Match::Confirmed
            } else {
                Match::Awaiting
            };
        }
        if self.owner != *owner {
            return Match::Superseded;
        }
        if incoming.unavailable {
            let attempted = match &self.intent {
                Intent::Play(uri) => {
                    uri == &incoming.track || incoming.context.as_ref() == Some(uri)
                }
                Intent::PlayTracks(uris) => uris.first() == Some(&incoming.track),
                Intent::Toggle { playing: false, .. } => same_track,
                _ => false,
            };
            return if attempted {
                Match::Rejected
            } else {
                Match::Awaiting
            };
        }
        let confirmed = match &self.intent {
            Intent::Toggle { playing: true, .. } => same_track && !incoming.playing,
            Intent::Toggle {
                playing: false,
                position,
                ..
            } => {
                protocol
                    && same_track
                    && same_context
                    && incoming.playing
                    && near_position(incoming, f64::from(*position) / 1000.0, elapsed)
            }
            Intent::Previous | Intent::Next => {
                !incoming.track.is_empty()
                    && (!same_track
                        || f64::from(incoming.position_ms) / 1000.0 + 1.0 < self.baseline.position)
            }
            Intent::Seek(position) => {
                same_track && near_position(incoming, f64::from(*position) / 1000.0, elapsed)
            }
            Intent::Shuffle(enabled) => same_track && incoming.shuffle == *enabled,
            Intent::Repeat { target, .. } => {
                same_track
                    && incoming.repeat_context == target.context
                    && incoming.repeat_track == target.track
            }
            Intent::Play(uri) => {
                incoming.playing
                    && if uri.starts_with("spotify:track:") {
                        &incoming.track == uri
                    } else {
                        incoming.context.as_ref() == Some(uri)
                    }
            }
            Intent::PlayTracks(uris) => incoming.playing && uris.first() == Some(&incoming.track),
            Intent::Transfer { .. } | Intent::Add(_) | Intent::Replace { .. } => false,
        };
        if confirmed {
            Match::Confirmed
        } else {
            Match::Awaiting
        }
    }

    pub(super) fn queue(&self, queue: &engine::Queue, playback: &Playback, owner: &Owner) -> Match {
        if !self.is_queue() || self.new_observation(queue.sequence).is_none() {
            return Match::Awaiting;
        }
        if self.owner != *owner || playback.context != self.baseline.context {
            return Match::Superseded;
        }
        if queue.track != playback.uri
            || queue.context != playback.context
            || queue.revision.is_none()
        {
            return Match::Awaiting;
        }
        let rows = upcoming(queue);
        let confirmed = match &self.intent {
            Intent::Add(_) => self.added.as_ref().is_some_and(|expected| {
                let mut counts = HashMap::new();
                for (_, track) in &rows {
                    if track.provider == "queue" && expected.contains_key(&track.uri) {
                        *counts.entry(&track.uri).or_insert(0) += 1;
                    }
                }
                expected
                    .iter()
                    .all(|(uri, count)| counts.get(uri).is_some_and(|seen| seen >= count))
            }),
            Intent::Replace { removed, .. } => rows
                .iter()
                .all(|(_, row)| !removed.contains(&Occurrence::of(row))),
            _ => false,
        };
        if confirmed {
            Match::Confirmed
        } else {
            Match::Awaiting
        }
    }
}

impl Drop for Pending {
    fn drop(&mut self) {
        self.dispatch.retired.store(true, Ordering::Release);
    }
}

fn near_position(incoming: &engine::Playback, position: f64, elapsed: Duration) -> bool {
    let seen = f64::from(incoming.position_ms) / 1000.0;
    let advance = if incoming.playing {
        elapsed.as_secs_f64()
    } else {
        0.0
    };
    (position - 1.0..=position + advance + 1.0).contains(&seen)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn observation(sequence: u64) -> engine::Playback {
        engine::Playback {
            sequence,
            generation: 7,
            position_ms: 12_000,
            duration_ms: 90_000,
            timestamp_ms: 0,
            playing: true,
            unavailable: false,
            rejected: false,
            shuffle: false,
            repeat_track: false,
            repeat_context: false,
            local: true,
            track: "spotify:track:example".into(),
            context: None,
        }
    }

    #[test]
    fn resume_matches_contextless_cluster_and_rejects_old_or_local_only_evidence() {
        let baseline = Playback {
            uri: observation(0).track,
            position: 12.0,
            ..Playback::default()
        };
        let pending = Pending::new(
            Intent::Toggle {
                playing: false,
                track: baseline.uri.clone(),
                context: String::new(),
                position: 12_000,
            },
            &baseline,
            Owner::Local,
            None,
        );
        pending.dispatch.started.set((10, Instant::now())).unwrap();
        let matches = |sequence, protocol| {
            pending.playback(&observation(sequence), &Owner::Local, None, protocol)
        };
        assert!(matches(9, true) == Match::Awaiting);
        assert!(matches(11, false) == Match::Awaiting);
        assert!(matches(11, true) == Match::Confirmed);
    }

    #[test]
    fn confirmation_never_retires_an_unsettled_write_permit() {
        let mut pending = Pending::new(
            Intent::Replace {
                payload: serde_json::Value::Null,
                removed: Vec::new(),
            },
            &Playback::default(),
            Owner::Remote("speaker".into()),
            None,
        );
        let permit = Arc::clone(&pending.dispatch);
        permit
            .started
            .set((10, Instant::now() - Duration::from_secs(8)))
            .unwrap();
        assert!(!pending.expired(), "the write still owns the slot");
        assert!(!pending.record(Match::Confirmed));
        assert!(permit.begin(), "an in-flight batch may finish");
        assert!(pending.acknowledge());
        drop(pending);
        assert!(!permit.begin(), "a settled permit cannot send again");
    }
}
