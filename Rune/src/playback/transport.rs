use crate::playback::selection_load_policy::{SelectionLoadPolicy, SelectionOrder};
use crate::playback::*;

/// How often the playing-event waits re-read [`PlayingEventStamp`].
pub(crate) const PLAYING_EVENT_POLL_INTERVAL: Duration = Duration::from_millis(25);

/// Maximum time to confirm that a reconnect restored the interrupted playback.
pub(crate) const REHYDRATION_WINDOW: Duration = Duration::from_secs(5);

/// A context load carries an optional current-track hint and a seek position.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ResumeLoadTarget {
    Context {
        uri: String,
        track_hint: Option<String>,
        position_ms: u32,
    },
    Track {
        uri: String,
        position_ms: u32,
    },
}

impl ResumeLoadTarget {
    /// Builds a Spirc load with the captured start position and playback modes.
    fn into_load(self, policy: SelectionLoadPolicy) -> (LoadRequest, &'static str) {
        match self {
            Self::Context {
                uri,
                track_hint,
                position_ms,
            } => {
                let playing_track = track_hint.map(PlayingTrack::Uri);
                debug!(
                    "Resume fallback: loading context {} at {}ms (track hint: {:?})",
                    uri, position_ms, playing_track
                );
                (
                    LoadRequest::from_context_uri(uri, policy.options(position_ms, playing_track)),
                    "Resume fallback context load",
                )
            }
            Self::Track { uri, position_ms } => {
                debug!(
                    "Resume fallback: loading single track {} at {}ms",
                    uri, position_ms
                );
                (
                    LoadRequest::from_tracks(vec![uri], policy.options(position_ms, None)),
                    "Resume fallback track load",
                )
            }
        }
    }
}

fn nonempty_uri(uri: Option<String>) -> Option<String> {
    uri.filter(|uri| !uri.is_empty())
}

/// Capture the interrupted playback before the new cluster can publish another context.
pub(crate) fn capture_resume_targets() -> Vec<(ResumeLoadTarget, SelectionLoadPolicy)> {
    let context = CURRENT_CONTEXT_URI
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone();
    let track = CURRENT_TRACK_URI
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone();
    let position = RESUME_POSITION_MS.load(Ordering::SeqCst);
    resume_targets(
        nonempty_uri(context),
        track,
        if position > 0 {
            position
        } else {
            displayed_position_ms()
        },
    )
    .into_iter()
    .map(|target| {
        let order = match target {
            ResumeLoadTarget::Context { .. } => SelectionOrder::Context,
            ResumeLoadTarget::Track { .. } => SelectionOrder::Supplied,
        };
        (target, SelectionLoadPolicy::capture(order))
    })
    .collect()
}

fn resume_targets(
    context: Option<String>,
    track: Option<String>,
    position_ms: u32,
) -> Vec<ResumeLoadTarget> {
    let track = nonempty_uri(track);
    let mut targets = Vec::with_capacity(2);
    if let Some(uri) = context {
        targets.push(ResumeLoadTarget::Context {
            uri,
            track_hint: track.clone(),
            position_ms,
        });
    }
    if let Some(uri) = track {
        targets.push(ResumeLoadTarget::Track { uri, position_ms });
    }
    targets
}

/// Starts one attempt and records its event watermark under the generation gate.
pub(crate) fn queue_rehydration(
    generation: u64,
    spirc: &Spirc,
    (target, policy): (ResumeLoadTarget, SelectionLoadPolicy),
) -> Result<u64, CommandError> {
    with_current_generation_mutation(generation, || {
        if !rehydration_load_is_current(generation) || !is_active_device() {
            return Err(CommandError::NotConnected);
        }
        let sequence = playing_event_stamp().sequence;
        issue_load_target(spirc, target, policy, generation)
            .unwrap_or(Err(CommandError::Failed))
            .map(|()| sequence)
    })
    .unwrap_or(Err(CommandError::NotConnected))
}

/// Each attempt owns its evidence, and later fallbacks share the original deadline.
pub(crate) async fn rehydrate_targets<F: Future<Output = RehydrationOutcome>>(
    targets: Vec<(ResumeLoadTarget, SelectionLoadPolicy)>,
    mut submit: impl FnMut((ResumeLoadTarget, SelectionLoadPolicy)) -> Result<u64, CommandError>,
    mut confirm: impl FnMut(u64, Duration) -> F,
) -> RehydrationOutcome {
    let deadline = tokio::time::Instant::now() + REHYDRATION_WINDOW;
    let mut targets = targets.into_iter();
    while let Some(target) = targets.next() {
        let budget = deadline.saturating_duration_since(tokio::time::Instant::now());
        if budget.is_zero() {
            break;
        }
        match submit(target) {
            Ok(sequence) => match confirm(sequence, budget / (targets.len() as u32 + 1)).await {
                RehydrationOutcome::TimedOut => continue,
                outcome => return outcome,
            },
            Err(CommandError::NeedsReinitialization) => return RehydrationOutcome::NeedsReinit,
            Err(CommandError::Failed) => continue,
            Err(_) => break,
        }
    }
    RehydrationOutcome::TimedOut
}

/// How a rehydration window closed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RehydrationOutcome {
    /// Fresh local and protocol evidence confirmed the dispatched load in this generation.
    Playing,
    /// The Spirc command channel closed before the load could be queued.
    NeedsReinit,
    /// The window expired without matching playback evidence.
    TimedOut,
}

/// The reconnect owns this window until confirmation, timeout, or generation change.
pub(crate) fn rehydration_load_is_current(generation: u64) -> bool {
    generation != 0
        && SESSION_GENERATION.load(Ordering::SeqCst) == generation
        && with_connection(|c| c.resume_pending)
}

/// Wait for fresh Playing and protocol evidence from the generation that queued the load.
pub(crate) async fn wait_for_rehydration(
    generation: u64,
    previous_seq: u64,
    timeout: Duration,
) -> RehydrationOutcome {
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        let stamp = playing_event_stamp();
        let now = tokio::time::Instant::now();
        if !rehydration_load_is_current(generation) {
            return RehydrationOutcome::TimedOut;
        }
        if stamp.sequence > previous_seq
            && stamp.generation == generation
            && load_observation_confirmed(generation, None)
        {
            return RehydrationOutcome::Playing;
        }
        if now >= deadline {
            return RehydrationOutcome::TimedOut;
        }
        tokio::time::sleep_until(deadline.min(now + PLAYING_EVENT_POLL_INTERVAL)).await;
    }
}

/// Queues one `LoadRequest`. `None` means try the next fallback; a closed channel is terminal.
pub(crate) fn issue_load_target(
    spirc: &Spirc,
    target: ResumeLoadTarget,
    policy: SelectionLoadPolicy,
    generation: u64,
) -> Option<Result<(), CommandError>> {
    if !arm_load_observation(generation, target.clone()) {
        return Some(Err(CommandError::Failed));
    }
    let (load_request, what) = target.clone().into_load(policy);
    match spirc.load(load_request) {
        Ok(_) => Some(Ok(())),
        Err(e) => {
            discard_load_observation(generation, &target);
            match spirc_error(what, &e) {
                CommandError::NeedsReinitialization => {
                    Some(Err(CommandError::NeedsReinitialization))
                }
                _ => None,
            }
        }
    }
}

/// Sends pause and captures its acknowledged state before releasing the generation.
/// A later player or cluster observation is authoritative.
pub(crate) fn pause_playback(generation: u64) -> Result<(), CommandError> {
    match with_command_spirc(generation, |spirc| {
        spirc
            .pause()
            .map_err(|error| spirc_error("Pause", &error))?;
        clear_engine_playing();
        Ok(capture_local_playback_state(
            false,
            POSITION_MS.load(Ordering::SeqCst),
            generation,
        ))
    }) {
        Ok(notification) => {
            deliver_local_playback_state(notification);
            Ok(())
        }
        Err(error) => Err(error),
    }
}

#[cfg(test)]
mod native_resume_tests {
    use super::*;

    #[test]
    fn sticky_resume_preserves_context_first_track_fallback_and_seek_position() {
        let context = "spotify:playlist:interrupted".to_owned();
        let track = "spotify:track:interrupted".to_owned();
        assert_eq!(
            resume_targets(Some(context.clone()), Some(track.clone()), 54_321),
            [
                ResumeLoadTarget::Context {
                    uri: context.clone(),
                    track_hint: Some(track.clone()),
                    position_ms: 54_321,
                },
                ResumeLoadTarget::Track {
                    uri: track,
                    position_ms: 54_321
                },
            ]
        );
        assert_eq!(
            resume_targets(Some(context.clone()), Some(String::new()), 500),
            [ResumeLoadTarget::Context {
                uri: context,
                track_hint: None,
                position_ms: 500,
            }]
        );
        assert!(resume_targets(None, None, 0).is_empty());
    }

    #[tokio::test(start_paused = true)]
    async fn an_unconfirmed_context_falls_back_to_the_same_track_within_one_deadline() {
        let track = "spotify:track:saved".to_owned();
        let targets = resume_targets(
            Some("spotify:playlist:saved".into()),
            Some(track.clone()),
            900,
        )
        .into_iter()
        .map(|target| {
            (
                target,
                SelectionLoadPolicy::capture(SelectionOrder::Context),
            )
        })
        .collect();
        let started = tokio::time::Instant::now();
        let mut submitted = Vec::new();
        let outcome = rehydrate_targets(
            targets,
            |(target, _)| {
                submitted.push(target);
                Ok(submitted.len() as u64)
            },
            |sequence, budget| async move {
                assert!(budget <= REHYDRATION_WINDOW / 2);
                tokio::time::sleep(budget).await;
                if sequence == 1 {
                    RehydrationOutcome::TimedOut
                } else {
                    RehydrationOutcome::Playing
                }
            },
        )
        .await;
        assert!(matches!(
            submitted.first(),
            Some(ResumeLoadTarget::Context { .. })
        ));
        assert_eq!(
            submitted[1],
            ResumeLoadTarget::Track {
                uri: track,
                position_ms: 900
            }
        );
        assert_eq!(outcome, RehydrationOutcome::Playing);
        assert_eq!(started.elapsed(), REHYDRATION_WINDOW);
    }
}
