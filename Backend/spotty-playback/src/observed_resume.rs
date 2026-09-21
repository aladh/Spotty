use crate::*;
use librespot_core::dealer::protocol::TransferOptions;
use librespot_core::spclient::TransferRequest;

/// The requested resume no longer agrees with the observed session. Never retry it as a load.
pub(crate) const ERROR_RESUME_MISMATCH: i32 = -5;
/// Another resume owns the command slot. The caller may retry after it settles.
pub(crate) const ERROR_RESUME_BUSY: i32 = -6;

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
    pub(crate) protocol_player: Option<PlayerState>,
    protocol_active: bool,
    protocol_playing: bool,
    pub(crate) local: Option<ObservedResumeTarget>,
    local_context_known: bool,
    pub(crate) remote_owner: bool,
    load: Option<ObservedLoad>,
}

struct ObservedLoad {
    target: ResumeLoadTarget,
    after_revision: u64,
    after_playing: u64,
    started: std::time::Instant,
}

/// Reuse the generation's local/protocol evidence for recovery loads, too. Queuing a load
/// cannot satisfy this receipt; both consumers must describe its target after dispatch.
pub(crate) fn arm_load_observation(generation: u64, target: ResumeLoadTarget) -> bool {
    with_engine_owned(generation, |engine| {
        engine.observed_resume.load = Some(ObservedLoad {
            target,
            after_revision: engine.observed_resume.revision,
            after_playing: engine.playing_event().sequence,
            started: std::time::Instant::now(),
        });
    })
    .is_ok()
}

pub(crate) fn load_observation_confirmed(
    generation: u64,
    expected_load: Option<&ResumeLoadTarget>,
) -> bool {
    with_engine_owned(generation, |engine| {
        let state = &engine.observed_resume;
        let Some(load) = &state.load else {
            return false;
        };
        if expected_load.is_some_and(|target| *target != load.target) {
            return false;
        }
        let Some(observed) = &state.observed else {
            return false;
        };
        let expected = match &load.target {
            ResumeLoadTarget::Context {
                uri,
                track_hint,
                position_ms,
            } => ObservedResumeTarget {
                track_uri: track_hint
                    .clone()
                    .filter(|s| !s.is_empty())
                    .unwrap_or_else(|| observed.track_uri.clone()),
                context_uri: Some(uri.clone()),
                position_ms: *position_ms,
            },
            ResumeLoadTarget::Track { uri, position_ms } => ObservedResumeTarget {
                track_uri: uri.clone(),
                context_uri: None,
                position_ms: *position_ms,
            },
        };
        let playing = engine.playing_event();
        engine.is_playing()
            && playing.generation == generation
            && playing.sequence > load.after_playing
            && state.confirms_playing(
                &expected,
                load.after_revision,
                load.started.elapsed().as_millis().min(u32::MAX as u128) as u32,
            )
    })
    .unwrap_or(false)
}

pub(crate) fn record_resume_observation(stamp: SnapshotStamp, observation: &PlaybackObservation) {
    let _ =
        with_engine_owned(stamp.session_generation, |engine| {
            let state = &mut engine.observed_resume;
            if stamp.revision <= state.revision {
                return;
            }
            state.revision = stamp.revision;
            state.protocol_active = observation.is_active_device;
            state.protocol_playing = observation.is_playing && !observation.is_paused;
            // Only protocol observations reach this function. Empty context is an explicit
            // clear; never inherit another track's context or the reconnect sticky getter.
            let context_uri = observation
                .context_uri
                .clone()
                .filter(|uri| !uri.is_empty());
            let target = (!observation.track_uri.is_empty() && !observation.track_unavailable)
                .then(|| ObservedResumeTarget {
                    track_uri: observation.track_uri.clone(),
                    context_uri,
                    position_ms: observation.position_ms.clamp(0, u32::MAX as i64) as u32,
                });
            if let (Some(local), Some(protocol)) = (&mut state.local, &target) {
                if local.track_uri == protocol.track_uri {
                    local.context_uri = protocol.context_uri.clone();
                    state.local_context_known = true;
                }
            }
            state.observed = target;
        });
}

/// Only real Playing/Paused events establish a loaded local track. Command acknowledgements,
/// cluster callbacks and Loading events cannot authorize the final Play.
pub(crate) fn record_local_resume_position(generation: u64, track_uri: &str, position_ms: u32) {
    let _ = with_engine_owned(generation, |engine| {
        let state = &mut engine.observed_resume;
        let context = state
            .observed
            .as_ref()
            .filter(|target| target.track_uri == track_uri)
            .map(|target| target.context_uri.clone())
            .or_else(|| {
                state
                    .local
                    .as_ref()
                    .filter(|target| state.local_context_known && target.track_uri == track_uri)
                    .map(|target| target.context_uri.clone())
            });
        state.local_context_known = context.is_some();
        state.local = Some(ObservedResumeTarget {
            track_uri: track_uri.to_owned(),
            context_uri: context.flatten(),
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
    fn confirms_playing(
        &self,
        expected: &ObservedResumeTarget,
        after_revision: u64,
        elapsed_ms: u32,
    ) -> bool {
        self.revision > after_revision
            && self.protocol_active
            && self.protocol_playing
            && !self.remote_owner
            && self.local_context_known
            && self.local.as_ref().is_some_and(|local| {
                local.track_uri == expected.track_uri
                    && local.context_uri == expected.context_uri
                    && local.position_ms.saturating_add(1_000) >= expected.position_ms
                    && local.position_ms
                        <= expected
                            .position_ms
                            .saturating_add(elapsed_ms)
                            .saturating_add(1_000)
            })
            && self.observed.as_ref().is_some_and(|observed| {
                observed.track_uri == expected.track_uri
                    && observed.context_uri == expected.context_uri
                    && observed.position_ms.saturating_add(1_000) >= expected.position_ms
                    && observed.position_ms
                        <= expected
                            .position_ms
                            .saturating_add(elapsed_ms)
                            .saturating_add(1_000)
            })
    }

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
            && !local_active
            && !self
                .observed
                .as_ref()
                .is_some_and(|target| expected.matches(target))
        {
            return ResumeAction::Reject;
        }
        // Restoration, protocol ownership and decoder position arrive independently. A
        // provisional sample is not a permanent mismatch while our paused transfer is still
        // settling. Keep the same bounded wait; never send Play until both sources agree.
        if transferred
            && (!self.protocol_active
                || !self
                    .observed
                    .as_ref()
                    .is_some_and(|target| expected.matches(target)))
        {
            return ResumeAction::Wait;
        }
        if local_active {
            if let Some(local) = &self.local {
                if !self.local_context_known {
                    return if transferred {
                        ResumeAction::Wait
                    } else {
                        ResumeAction::Reject
                    };
                }
                return if expected.matches(local) {
                    ResumeAction::Play
                } else if transferred {
                    ResumeAction::Wait
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
/// A concurrent resume returns -6 (busy); serialize commands and retry after it settles.
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
    let claimed = match with_engine_owned(generation, |engine| engine.claim_resume()) {
        Ok(claimed) => claimed,
        Err(_) => return ERROR_RESUME_MISMATCH,
    };
    if !claimed {
        return ERROR_RESUME_BUSY;
    }
    // Unlike the legacy resume guard, a retired call must not release a replacement's claim.
    struct ObservedResumeGuard {
        generation: u64,
        track_uri: String,
        sent_play: bool,
        succeeded: bool,
    }
    impl Drop for ObservedResumeGuard {
        fn drop(&mut self) {
            let _ = with_current_generation_mutation(self.generation, || {
                let _ = with_engine_owned(self.generation, |engine| {
                    if self.sent_play
                        && !self.succeeded
                        && !engine.observed_resume.remote_owner
                        && engine
                            .observed_resume
                            .local
                            .as_ref()
                            .is_some_and(|local| local.track_uri == self.track_uri)
                    {
                        if let Some(spirc) = engine.spirc.as_ref() {
                            let _ = spirc.pause();
                        }
                    }
                    engine.release_resume();
                });
            });
        }
    }
    let mut guard = ObservedResumeGuard {
        generation,
        track_uri: expected.track_uri.clone(),
        sent_play: false,
        succeeded: false,
    };
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    let mut transferred = false;
    let mut restoration: Option<tokio::sync::oneshot::Receiver<()>> = None;
    let mut restored = false;
    loop {
        if let Some(receiver) = restoration.as_mut() {
            match receiver.try_recv() {
                Ok(()) => {
                    restored = true;
                    restoration = None;
                }
                Err(tokio::sync::oneshot::error::TryRecvError::Empty) => {}
                Err(tokio::sync::oneshot::error::TryRecvError::Closed) => {
                    return ERROR_RESUME_MISMATCH;
                }
            }
        }
        // Check the generation and evidence at the channel-send boundary. No callback or
        // blocking work occurs while this gate or the engine lock is held.
        let step = with_current_generation_mutation(generation, || {
            with_engine_owned(generation, |engine| {
                let action = if transferred && !restored {
                    ResumeAction::Wait
                } else {
                    engine.observed_resume.action(
                        &expected,
                        engine.connection.is_active_device,
                        transferred,
                    )
                };
                let Some(spirc) = engine.spirc.as_ref() else {
                    return Err(ERROR_NOT_CONNECTED);
                };
                let result = match action {
                    ResumeAction::TransferPaused => {
                        // Evidence from a previous local load cannot acknowledge this transfer.
                        engine.observed_resume.local = None;
                        engine.observed_resume.local_context_known = false;
                        let Some(snapshot) = engine.observed_resume.protocol_player.clone() else {
                            return Err(ERROR_RESUME_MISMATCH);
                        };
                        spirc
                            .transfer_observed(
                                TransferRequest {
                                    transfer_options: TransferOptions {
                                        restore_paused: Some("pause".to_owned()),
                                        ..Default::default()
                                    },
                                },
                                snapshot,
                            )
                            .map(Some)
                    }
                    ResumeAction::Play => spirc.play().map(|_| None),
                    ResumeAction::Wait => {
                        return Ok((
                            action,
                            engine.playing_event(),
                            engine.observed_resume.revision,
                            None,
                        ))
                    }
                    ResumeAction::Reject => return Err(ERROR_RESUME_MISMATCH),
                };
                let restoration = result.map_err(|_| ERROR_NEEDS_REINIT)?;
                Ok((
                    action,
                    engine.playing_event(),
                    engine.observed_resume.revision,
                    restoration,
                ))
            })
            .unwrap_or(Err(ERROR_RESUME_MISMATCH))
        })
        .unwrap_or(Err(ERROR_RESUME_MISMATCH));
        match step {
            Ok((ResumeAction::TransferPaused, _, _, receiver)) => {
                transferred = true;
                restoration = receiver;
            }
            Ok((ResumeAction::Play, before, protocol_revision, _)) => {
                guard.sent_play = true;
                let play_started = std::time::Instant::now();
                // Transfer and Playing confirmation have independent budgets. The complete
                // call remains below the app's eight-second command deadline.
                let playing_deadline = std::time::Instant::now() + Duration::from_secs(2);
                while std::time::Instant::now() < playing_deadline {
                    let observed = with_engine_owned(generation, |engine| {
                        let stamp = engine.playing_event();
                        stamp.generation == generation
                            && stamp.sequence > before.sequence
                            && engine.connection.is_active_device
                            && engine.observed_resume.confirms_playing(
                                &expected,
                                protocol_revision,
                                play_started.elapsed().as_millis() as u32,
                            )
                            && !engine.observed_resume.remote_owner
                            && engine.observed_resume.local_context_known
                            && engine.observed_resume.local.as_ref().is_some_and(|target| {
                                target.track_uri == expected.track_uri
                                    && target.context_uri == expected.context_uri
                            })
                    });
                    match observed {
                        Ok(true) => {
                            guard.succeeded = true;
                            return 0;
                        }
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
        state.local_context_known = true;
        state.protocol_active = true;
        assert_eq!(state.action(&expected, true, true), ResumeAction::Play);
        assert_eq!(state.action(&expected, true, false), ResumeAction::Play);
        // Local pause/seek timing can advance without a corresponding cluster snapshot.
        state.observed.as_mut().unwrap().position_ms = 0;
        assert_eq!(state.action(&expected, true, false), ResumeAction::Play);
    }

    #[test]
    fn local_delivery_cannot_replace_protocol_evidence_or_inherit_another_context() {
        let _guard = lock_lifecycle_test_globals();
        let generation = SESSION_GENERATION.load(Ordering::SeqCst);
        let saved = with_engine(|engine| std::mem::take(&mut engine.observed_resume));
        let mut protocol = PlayerState {
            context_uri: "spotify:playlist:fixture".into(),
            position_as_of_timestamp: 152_000,
            ..Default::default()
        };
        protocol.track = protobuf::MessageField::some(ProvidedTrack {
            uri: "spotify:track:current".into(),
            ..Default::default()
        });
        let stamp = |revision| SnapshotStamp {
            revision,
            session_generation: generation,
        };
        record_resume_observation(
            stamp(1),
            &playback_observation_from_player_state(&protocol, false),
        );
        let mut local = playback_observation_from_player_state(&protocol, true);
        local.track_uri = "spotify:track:different".into();
        local.context_uri = None;
        extern "C" fn ignore_snapshot(_: *const SpottyPlaybackSnapshot) {}
        send_playback_snapshot(ignore_snapshot, stamp(2), &local);
        assert_eq!(
            with_engine(|engine| engine.observed_resume.observed.clone()),
            Some(target("current", 152_000))
        );

        // A local event arriving before the new protocol track has unknown context and waits.
        record_local_resume_position(generation, "spotify:track:different", 152_000);
        let expected = ObservedResumeTarget {
            context_uri: None,
            ..target("different", 152_000)
        };
        assert_eq!(
            with_engine(|engine| engine.observed_resume.action(&expected, true, true)),
            ResumeAction::Wait
        );
        // A later delivery can still contain the previous protocol track. It must not erase
        // actual local readiness; the matching protocol context can arrive after this push.
        record_resume_observation(
            stamp(3),
            &playback_observation_from_player_state(&protocol, true),
        );
        assert!(with_engine(|engine| engine.observed_resume.local.is_some()));
        protocol.track.mut_or_insert_default().uri = expected.track_uri.clone();
        protocol.context_uri.clear();
        record_resume_observation(
            stamp(4),
            &playback_observation_from_player_state(&protocol, true),
        );
        assert_eq!(
            with_engine(|engine| engine.observed_resume.action(&expected, true, true)),
            ResumeAction::Play
        );
        assert_eq!(
            with_engine(|engine| engine.observed_resume.observed.clone()),
            Some(expected)
        );
        with_engine(|engine| engine.observed_resume = saved);
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
                local_context_known: true,
                protocol_active: true,
                ..Default::default()
            };
            assert_eq!(state.action(&expected, false, false), ResumeAction::Reject);
            assert_eq!(state.action(&expected, true, true), ResumeAction::Wait);
        }
        let state = ObservedResumeState {
            observed: Some(expected.clone()),
            local: Some(expected.clone()),
            local_context_known: true,
            remote_owner: true,
            ..Default::default()
        };
        assert_eq!(state.action(&expected, true, false), ResumeAction::Reject);
        assert_eq!(
            ObservedResumeState::default().action(&expected, false, false),
            ResumeAction::Reject
        );
    }

    #[test]
    fn paused_transfer_waits_for_converging_protocol_and_local_positions() {
        let expected = target("current", 152_000);
        let mut state = ObservedResumeState {
            observed: Some(target("current", 0)),
            local: Some(target("current", 0)),
            local_context_known: true,
            protocol_active: true,
            ..Default::default()
        };
        assert_eq!(state.action(&expected, true, true), ResumeAction::Wait);
        state.observed = Some(expected.clone());
        assert_eq!(state.action(&expected, true, true), ResumeAction::Wait);
        state.local = Some(expected.clone());
        assert_eq!(state.action(&expected, true, true), ResumeAction::Play);
        state.remote_owner = true;
        assert_eq!(state.action(&expected, true, true), ResumeAction::Reject);
    }

    #[test]
    fn transport_trace_recovery_load_requires_fresh_target_and_ownership_evidence() {
        let _guard = lock_lifecycle_test_globals();
        let generation = SESSION_GENERATION.load(Ordering::SeqCst);
        let saved = with_engine(|engine| std::mem::take(&mut engine.observed_resume));
        let saved_playing = engine_is_playing();
        let saved_stamp = playing_event_stamp();
        let expected = target("current", 152_000);
        with_engine(|engine| {
            engine.observed_resume = ObservedResumeState {
                revision: 10,
                observed: Some(expected.clone()),
                local: Some(expected.clone()),
                local_context_known: true,
                protocol_active: true,
                protocol_playing: true,
                ..Default::default()
            }
        });
        assert!(arm_load_observation(
            generation,
            ResumeLoadTarget::Context {
                uri: expected.context_uri.clone().unwrap(),
                track_hint: Some(expected.track_uri.clone()),
                position_ms: 152_000,
            }
        ));
        assert!(
            !load_observation_confirmed(generation, None),
            "dispatch alone cannot confirm a load"
        );
        publish_playing_event(generation);
        assert!(
            !load_observation_confirmed(generation, None),
            "a local event is not fresh protocol confirmation"
        );
        with_engine(|engine| engine.observed_resume.revision = 11);
        assert!(load_observation_confirmed(generation, None));
        assert!(
            !load_observation_confirmed(
                generation,
                Some(&ResumeLoadTarget::Track {
                    uri: "spotify:track:older-command".into(),
                    position_ms: 0,
                })
            ),
            "a replacement load cannot confirm an earlier command's different target"
        );
        assert!(!load_observation_confirmed(
            generation.wrapping_add(1),
            None
        ));
        for wrong in [
            target("different", 152_000),
            target("current", 0),
            ObservedResumeTarget {
                context_uri: None,
                ..expected.clone()
            },
        ] {
            with_engine(|engine| engine.observed_resume.observed = Some(wrong.clone()));
            assert!(!load_observation_confirmed(generation, None));
            with_engine(|engine| {
                engine.observed_resume.observed = Some(expected.clone());
                engine.observed_resume.local = Some(wrong);
            });
            assert!(!load_observation_confirmed(generation, None));
            with_engine(|engine| engine.observed_resume.local = Some(expected.clone()));
        }
        with_engine(|engine| engine.observed_resume.remote_owner = true);
        assert!(!load_observation_confirmed(generation, None));
        with_engine(|engine| {
            engine.observed_resume.remote_owner = false;
            engine.observed_resume.protocol_active = false;
        });
        assert!(!load_observation_confirmed(generation, None));
        with_engine(|engine| engine.observed_resume = saved);
        set_engine_playing_for_test(saved_playing);
        replace_playing_event_stamp_for_test(saved_stamp);
    }

    #[test]
    fn local_playing_without_new_protocol_ownership_cannot_confirm_resume() {
        let expected = target("current", 152_000);
        let mut state = ObservedResumeState {
            revision: 10,
            observed: Some(expected.clone()),
            local: Some(expected.clone()),
            local_context_known: true,
            ..Default::default()
        };
        assert!(!state.confirms_playing(&expected, 10, 500));
        state.protocol_active = true;
        state.protocol_playing = true;
        assert!(
            !state.confirms_playing(&expected, 10, 500),
            "pre-dispatch protocol state is not confirmation"
        );
        state.revision = 11;
        assert!(state.confirms_playing(&expected, 10, 500));
        state.observed.as_mut().unwrap().position_ms -= 1_500;
        assert!(
            !state.confirms_playing(&expected, 10, 1_500),
            "elapsed time cannot authorize a backwards jump"
        );
        state.observed = Some(expected.clone());
        state.observed.as_mut().unwrap().position_ms += 1_500;
        assert!(
            state.confirms_playing(&expected, 10, 1_500),
            "confirmation includes elapsed playback time"
        );
        state.observed.as_mut().unwrap().track_uri = target("wrong", 0).track_uri;
        assert!(!state.confirms_playing(&expected, 10, 1_500));
        state.observed = Some(expected.clone());
        state.remote_owner = true;
        assert!(!state.confirms_playing(&expected, 10, 500));
    }
}
