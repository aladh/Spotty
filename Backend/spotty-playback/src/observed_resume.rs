use crate::*;
use librespot_core::dealer::protocol::TransferOptions;
use librespot_core::spclient::TransferRequest;

/// The requested resume no longer agrees with the observed session. Never retry it as a load.
pub(crate) const ERROR_RESUME_MISMATCH: i32 = -5;

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ObservedResumeTarget {
    track_uri: String,
    context_uri: Option<String>,
    position_ms: u32,
}

impl ObservedResumeTarget {
    fn matches(&self, other: &Self) -> bool {
        self.track_uri == other.track_uri
            && self.context_uri == other.context_uri
            && self.position_ms.abs_diff(other.position_ms) <= 1_000
    }
}

/// Protocol observations and local paused/playing evidence share the engine generation lock.
/// A cluster's track is not evidence that this process has loaded that track.
#[derive(Default)]
pub(crate) struct ObservedResumeState {
    revision: u64,
    observed: Option<ObservedResumeTarget>,
    pub(crate) local: Option<ObservedResumeTarget>,
    pub(crate) remote_owner: bool,
}

pub(crate) fn record_resume_observation(stamp: SnapshotStamp, observation: &PlaybackObservation) {
    let _ =
        with_engine_owned(stamp.session_generation, |engine| {
            let state = &mut engine.observed_resume;
            if stamp.revision <= state.revision {
                return;
            }
            state.revision = stamp.revision;
            let context_uri = observation
                .context_uri
                .clone()
                .or_else(|| {
                    state
                        .local
                        .as_ref()
                        .filter(|target| target.track_uri == observation.track_uri)
                        .and_then(|target| target.context_uri.clone())
                })
                .or_else(|| {
                    state
                        .observed
                        .as_ref()
                        .and_then(|target| target.context_uri.clone())
                })
                .filter(|uri| !uri.is_empty());
            let target = (!observation.track_uri.is_empty() && !observation.track_unavailable)
                .then(|| ObservedResumeTarget {
                    track_uri: observation.track_uri.clone(),
                    context_uri,
                    position_ms: observation.position_ms.clamp(0, u32::MAX as i64) as u32,
                });
            state.observed = target;
        });
}

/// Only real Playing/Paused events establish a loaded local track. Command acknowledgements,
/// cluster callbacks and Loading events cannot authorize the final Play.
pub(crate) fn record_local_resume_position(generation: u64, track_uri: &str, position_ms: u32) {
    let context_uri = CURRENT_CONTEXT_URI
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .clone()
        .filter(|uri| !uri.is_empty());
    let _ = with_engine_owned(generation, |engine| {
        engine.observed_resume.local = Some(ObservedResumeTarget {
            track_uri: track_uri.to_owned(),
            context_uri,
            position_ms,
        });
    });
}

pub(crate) fn update_local_resume_position(generation: u64, position_ms: u32) {
    let _ = with_engine_owned(generation, |engine| {
        if let Some(local) = &mut engine.observed_resume.local {
            local.position_ms = position_ms;
        }
    });
}

#[derive(Debug, PartialEq, Eq)]
enum ResumeAction {
    TransferPaused,
    Play,
    Wait,
    Reject,
}

impl ObservedResumeState {
    fn action(
        &self,
        expected: &ObservedResumeTarget,
        local_active: bool,
        transferred: bool,
    ) -> ResumeAction {
        if self.remote_owner {
            return ResumeAction::Reject;
        }
        if !transferred
            && !self
                .observed
                .as_ref()
                .is_some_and(|target| expected.matches(target))
        {
            return ResumeAction::Reject;
        }
        if local_active {
            if let Some(local) = &self.local {
                return if expected.matches(local) {
                    ResumeAction::Play
                } else {
                    ResumeAction::Reject
                };
            }
            // Activation without a loaded player is not a valid resume target.
            return if transferred {
                ResumeAction::Wait
            } else {
                ResumeAction::Reject
            };
        }
        if transferred {
            return ResumeAction::Wait;
        }
        if self
            .observed
            .as_ref()
            .is_some_and(|target| expected.matches(target))
        {
            ResumeAction::TransferPaused
        } else {
            ResumeAction::Reject
        }
    }
}

/// Resume exactly the displayed protocol track at its paused position in this generation.
///
/// Cold joins restore the Connect session paused, preserving its context, queue and options.
/// Play is sent only after local player evidence matches the requested track/context/position.
/// A missing, changed or timed-out snapshot returns -5 without loading a fallback track.
/// Strings are borrowed for this call and copied before dispatch; null context means no context.
#[no_mangle]
pub extern "C" fn spotty_playback_resume_observed(
    track_uri: *const c_char,
    context_uri: SpottyNullableCString,
    position_ms: u32,
    session_generation: u64,
) -> SpottyPlaybackResult {
    ffi_command("spotty_playback_resume_observed", || {
        let Some(track_uri) = (unsafe { c_string_arg(track_uri) }) else {
            return ERROR_RESUME_MISMATCH;
        };
        if track_uri.is_empty() {
            return ERROR_RESUME_MISMATCH;
        }
        let expected = ObservedResumeTarget {
            track_uri,
            context_uri: unsafe { c_string_arg(context_uri) }.filter(|uri| !uri.is_empty()),
            position_ms,
        };
        resume_observed(expected, session_generation)
    })
}

fn resume_observed(expected: ObservedResumeTarget, generation: u64) -> i32 {
    if with_engine_owned(generation, |_| ()).is_err() {
        return ERROR_RESUME_MISMATCH;
    }
    if let Err(error) = require_session_connected() {
        return error;
    }
    let claimed = with_engine_owned(generation, |engine| engine.claim_resume()).unwrap_or(false);
    if !claimed {
        return ERROR_RESUME_MISMATCH;
    }
    // Unlike the legacy resume guard, a retired call must not release a replacement's claim.
    struct ObservedResumeGuard(u64);
    impl Drop for ObservedResumeGuard {
        fn drop(&mut self) {
            let _ = with_engine_owned(self.0, |engine| engine.release_resume());
        }
    }
    let _guard = ObservedResumeGuard(generation);
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    let mut transferred = false;
    loop {
        // Check the generation and evidence at the channel-send boundary. No callback or
        // blocking work occurs while this gate or the engine lock is held.
        let step = with_current_generation_mutation(generation, || {
            with_engine_owned(generation, |engine| {
                let action = engine.observed_resume.action(
                    &expected,
                    engine.connection.is_active_device,
                    transferred,
                );
                let Some(spirc) = engine.spirc.as_ref() else {
                    return Err(ERROR_NOT_CONNECTED);
                };
                let result = match action {
                    ResumeAction::TransferPaused => spirc.transfer(Some(TransferRequest {
                        transfer_options: TransferOptions {
                            restore_paused: Some("pause".to_owned()),
                            ..Default::default()
                        },
                    })),
                    ResumeAction::Play => spirc.play(),
                    ResumeAction::Wait => return Ok((action, engine.playing_event())),
                    ResumeAction::Reject => return Err(ERROR_RESUME_MISMATCH),
                };
                result.map_err(|_| ERROR_NEEDS_REINIT)?;
                Ok((action, engine.playing_event()))
            })
            .unwrap_or(Err(ERROR_RESUME_MISMATCH))
        })
        .unwrap_or(Err(ERROR_RESUME_MISMATCH));
        match step {
            Ok((ResumeAction::TransferPaused, _)) => transferred = true,
            Ok((ResumeAction::Play, before)) => {
                while std::time::Instant::now() < deadline {
                    let observed = with_engine_owned(generation, |engine| {
                        let stamp = engine.playing_event();
                        stamp.generation == generation
                            && stamp.sequence > before.sequence
                            && engine.observed_resume.local.as_ref().is_some_and(|target| {
                                target.track_uri == expected.track_uri
                                    && target.context_uri == expected.context_uri
                            })
                    });
                    match observed {
                        Ok(true) => return 0,
                        Err(_) => return ERROR_RESUME_MISMATCH,
                        _ => std::thread::sleep(PLAYING_EVENT_POLL_INTERVAL),
                    }
                }
                return ERROR_RESUME_MISMATCH;
            }
            Err(error) => return error,
            _ => {}
        }
        if std::time::Instant::now() >= deadline {
            return ERROR_RESUME_MISMATCH;
        }
        std::thread::sleep(PLAYING_EVENT_POLL_INTERVAL);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn target(track: &str, position_ms: u32) -> ObservedResumeTarget {
        ObservedResumeTarget {
            track_uri: format!("spotify:track:{track}"),
            context_uri: Some("spotify:playlist:fixture".into()),
            position_ms,
        }
    }

    #[test]
    fn protocol_snapshot_capture_is_ordered_and_generation_scoped() {
        let _guard = lock_lifecycle_test_globals();
        let generation = SESSION_GENERATION.load(Ordering::SeqCst);
        let saved = with_engine(|engine| std::mem::take(&mut engine.observed_resume));
        let mut state = PlayerState {
            context_uri: "spotify:playlist:fixture".into(),
            position_as_of_timestamp: 152_000,
            ..Default::default()
        };
        state.track = protobuf::MessageField::some(ProvidedTrack {
            uri: "spotify:track:current".into(),
            ..Default::default()
        });
        let observe = |state: &PlayerState, revision, session_generation| {
            record_resume_observation(
                SnapshotStamp {
                    revision,
                    session_generation,
                },
                &playback_observation_from_player_state(state, false),
            );
        };
        observe(&state, 10, generation);
        let action = || {
            with_engine(|engine| {
                engine
                    .observed_resume
                    .action(&target("current", 152_000), false, false)
            })
        };
        assert_eq!(action(), ResumeAction::TransferPaused);
        state.track.mut_or_insert_default().uri = "spotify:track:stale".into();
        observe(&state, 9, generation);
        observe(&state, 11, generation.wrapping_add(1));
        assert_eq!(action(), ResumeAction::TransferPaused);
        state.context_uri.clear();
        observe(&state, 11, generation);
        assert_eq!(action(), ResumeAction::Reject);
        with_engine(|engine| engine.observed_resume = saved);
    }

    #[test]
    fn cold_hydration_requires_matching_local_evidence_before_play() {
        let expected = target("current", 152_000);
        let mut state = ObservedResumeState {
            observed: Some(expected.clone()),
            ..Default::default()
        };
        assert_eq!(
            state.action(&expected, false, false),
            ResumeAction::TransferPaused
        );
        assert_eq!(state.action(&expected, false, true), ResumeAction::Wait);
        assert_eq!(state.action(&expected, true, true), ResumeAction::Wait);
        state.local = Some(expected.clone());
        assert_eq!(state.action(&expected, true, true), ResumeAction::Play);
        assert_eq!(state.action(&expected, true, false), ResumeAction::Play);
    }

    #[test]
    fn mismatched_track_position_context_and_remote_takeover_fail_closed() {
        let expected = target("current", 152_000);
        for wrong in [
            target("different", 152_000),
            target("current", 0),
            ObservedResumeTarget {
                context_uri: None,
                ..expected.clone()
            },
        ] {
            let state = ObservedResumeState {
                observed: Some(wrong.clone()),
                local: Some(wrong),
                ..Default::default()
            };
            assert_eq!(state.action(&expected, false, false), ResumeAction::Reject);
            assert_eq!(state.action(&expected, true, true), ResumeAction::Reject);
        }
        let state = ObservedResumeState {
            observed: Some(expected.clone()),
            local: Some(expected.clone()),
            remote_owner: true,
            ..Default::default()
        };
        assert_eq!(state.action(&expected, true, false), ResumeAction::Reject);
        assert_eq!(
            ObservedResumeState::default().action(&expected, false, false),
            ResumeAction::Reject
        );
    }
}
