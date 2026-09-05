use crate::*;

/// What the event listener should do with one `recv` result.
///
/// `None` (a closed channel) must stop even when the listener generation is stale: skipping
/// that result would spin. A `Some` event from a replaced generation is ignored so a draining
/// predecessor cannot write position, track, or activity for a session that no longer exists.
/// `Apply` carries the event so the loop does not re-open the option after the policy decision.
///
/// `PlayerEvent` is `Debug` + `Clone` only, so this enum does not derive `Copy`/`Eq`.
#[derive(Debug, Clone)]
pub(crate) enum PlayerEventDisposition {
    Apply(PlayerEvent),
    IgnoreSuperseded,
    ChannelClosed,
}

pub(crate) fn player_event_disposition(
    event: Option<PlayerEvent>,
    listener_generation: u64,
    current_generation: u64,
) -> PlayerEventDisposition {
    match event {
        None => PlayerEventDisposition::ChannelClosed,
        Some(_) if !listener_may_act(listener_generation, current_generation) => {
            PlayerEventDisposition::IgnoreSuperseded
        }
        Some(event) => PlayerEventDisposition::Apply(event),
    }
}

/// Identity owned by one player-event listener.
///
/// At the pinned librespot revision, `PlayerInternal::handle_command_load` emits
/// `PlayRequestIdChanged` before `Loading`, and both a current-load failure and a preload failure
/// emit `Unavailable`. The latter reuses the active Playing/Paused request id for the preload
/// track. Keeping the latest request id and the track observed in its matching `Loading` event
/// lets the adapter tell those cases apart without a process-global state owner.
#[derive(Debug, Default, PartialEq, Eq)]
struct PlayerRequestState {
    current_play_request_id: Option<u64>,
    loading_track_uri: Option<String>,
}

impl PlayerRequestState {
    fn play_request_id_changed(&mut self, play_request_id: u64) {
        self.current_play_request_id = Some(play_request_id);
        self.loading_track_uri = None;
    }

    /// Records only a Loading event belonging to the latest request. A Loading event from an old
    /// request must not arm the unavailable notice for a later event.
    fn loading(&mut self, play_request_id: u64, track_uri: String) -> bool {
        if self.current_play_request_id != Some(play_request_id) {
            return false;
        }
        self.loading_track_uri = Some(track_uri);
        true
    }

    /// Playing and Paused are terminal transitions for the pending load. A preload failure that
    /// arrives while either state is active therefore cannot look like the current load failing,
    /// even when librespot reuses the same request id and URI.
    fn playing_or_paused(&mut self, play_request_id: u64) {
        if self.current_play_request_id == Some(play_request_id) {
            self.loading_track_uri = None;
        }
    }

    fn stopped_or_ended(&mut self, play_request_id: u64) {
        if self.current_play_request_id == Some(play_request_id) {
            self.clear();
        }
    }

    fn disconnected(&mut self) {
        self.clear();
    }

    /// Consumes a matching pending load so duplicate Unavailable events can never emit a second
    /// notice. The event id and URI are both checked because the pinned upstream event channel
    /// can carry a late event for a prior request.
    fn take_matching_unavailable(&mut self, play_request_id: u64, track_uri: &str) -> bool {
        let matches = self.matches_current_unavailable(play_request_id, track_uri);
        if matches {
            self.clear();
        }
        matches
    }

    fn matches_current_unavailable(&self, play_request_id: u64, track_uri: &str) -> bool {
        self.current_play_request_id == Some(play_request_id)
            && self.loading_track_uri.as_deref() == Some(track_uri)
    }

    fn clear(&mut self) {
        self.current_play_request_id = None;
        self.loading_track_uri = None;
    }
}

/// Reads the logical current-track identity without crossing into the callback. This is checked
/// while the generation mutation gate is held before an unavailable event can change playback
/// state, so a late event cannot overwrite a newer track's position or playing flag.
fn current_track_uri_matches(track_uri: &str) -> bool {
    CURRENT_TRACK_URI
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .as_deref()
        == Some(track_uri)
}

/// Live position captured at `SessionDisconnected`. Zero is how a missing baton reads, so a
/// second disconnect after `Stopped` reset the live position must not overwrite a good one.
pub(crate) fn resume_position_to_save_on_deactivation(live_position_ms: u32) -> Option<u32> {
    (live_position_ms > 0).then_some(live_position_ms)
}

/// Starts the player-event listener for `generation` and returns its stop sender and task.
///
/// The caller stores the sender in [`PLAYER_EVENT_TX`] and owns the returned task with the rest
/// of the generation's handles. Teardown takes the sender and signals stop before awaiting the
/// task and dropping the Player. This listener belongs to `generation` for its whole life: a
/// rebuild replaces the listener along with the session, so the captured value never has to
/// change underneath it. A Player clone is held until the task exits so the event channel
/// does not close while the pump is still running. The caller subscribes before constructing
/// Spirc, then starts this consumer after publication so early initialization events are buffered.
pub(crate) fn start_player_event_pump(
    player: Arc<Player>,
    mut event_channel: mpsc::UnboundedReceiver<PlayerEvent>,
    generation: u64,
) -> (mpsc::UnboundedSender<()>, JoinHandle<()>) {
    let (tx, mut rx) = mpsc::unbounded_channel::<()>();
    let player_keepalive = Arc::clone(&player);
    let task = RUNTIME.spawn(async move {
        // The upstream PlayerEvent stream carries a PlayRequestIdChanged event before each
        // requested load. Keep that identity with this listener so an Unavailable event can be
        // distinguished from a preload failure without introducing another process-global
        // owner. The state dies with this generation's listener.
        let mut request_state = PlayerRequestState::default();
        loop {
            tokio::select! {
                _ = rx.recv() => {
                    // Shutdown signal received
                    debug!("Player event listener shutting down (generation={})", generation);
                    break;
                }
                event = event_channel.recv() => {
                    // Drop everything from a superseded generation. A replaced listener
                    // drains asynchronously after its successor is live — the logs show old
                    // listeners still delivering seconds later — and without this guard it
                    // would keep writing position, track, playing and active-device state
                    // belonging to a session that no longer exists.
                    //
                    // `None` must still reach ChannelClosed and break. Skipping it would spin.
                    match player_event_disposition(
                        event,
                        generation,
                        SESSION_GENERATION.load(Ordering::SeqCst),
                    ) {
                        PlayerEventDisposition::IgnoreSuperseded => continue,
                        PlayerEventDisposition::ChannelClosed => break,
                        PlayerEventDisposition::Apply(event) => {
                            apply_player_event(event, generation, &mut request_state);
                        }
                    }
                }
            }
        }
        drop(player_keepalive);
    });
    (tx, task)
}

enum PlayerEventNotification {
    Playback(LocalPlaybackStateNotification),
    Connection(ConnectionStateNotification),
}

struct AppliedPlayerEvent {
    notifications: Vec<PlayerEventNotification>,
    recovery: Option<RecoveryIntent>,
}

impl PlayerEventNotification {
    fn deliver(self) {
        match self {
            Self::Playback(notification) => deliver_local_playback_state(notification),
            Self::Connection(notification) => deliver_connection_state_notification(notification),
        }
    }
}

fn apply_player_event(
    event: PlayerEvent,
    event_listener_generation: u64,
    request_state: &mut PlayerRequestState,
) {
    let Some(applied) = with_current_generation_mutation(event_listener_generation, || {
        let mut applied = AppliedPlayerEvent {
            notifications: Vec::with_capacity(2),
            recovery: None,
        };
        apply_player_event_locked(
            event,
            event_listener_generation,
            request_state,
            &mut applied,
        );
        applied
    }) else {
        return;
    };

    for notification in applied.notifications {
        notification.deliver();
    }
    if let Some(intent) = applied.recovery {
        spawn_reconnection_loop_for_generation(intent, event_listener_generation);
    }
}

fn apply_player_event_locked(
    event: PlayerEvent,
    event_listener_generation: u64,
    request_state: &mut PlayerRequestState,
    applied: &mut AppliedPlayerEvent,
) {
    match event {
        // Mirror librespot's Spirc request filter. The event is emitted before each load and
        // carries no track, so the following Loading event supplies the URI for the identity
        // check used by Unavailable.
        PlayerEvent::PlayRequestIdChanged { play_request_id } => {
            request_state.play_request_id_changed(play_request_id);
        }
        PlayerEvent::Playing {
            track_id,
            position_ms,
            play_request_id,
            ..
        } => {
            request_state.playing_or_paused(play_request_id);
            let track_uri = track_id.to_string();
            debug!(
                "PlayerEvent::Playing: logical track {} at {}ms",
                track_uri, position_ms
            );
            set_current_track_uri(track_uri);
            IS_PLAYING.store(true, Ordering::SeqCst);
            if store_active_device(true) {
                if let Some(notification) =
                    capture_connection_state_notification(event_listener_generation)
                {
                    applied
                        .notifications
                        .push(PlayerEventNotification::Connection(notification));
                }
            }
            publish_playing_event(event_listener_generation);
            // Playback is running again, so any saved resume point belongs
            // to a deactivation that has been recovered from.
            RESUME_POSITION_MS.store(0, Ordering::SeqCst);
            update_position(position_ms);
            // Send playback state update to Swift
            if let Some(notification) =
                capture_local_playback_state(true, position_ms, event_listener_generation)
            {
                applied
                    .notifications
                    .push(PlayerEventNotification::Playback(notification));
            }
        }
        PlayerEvent::Paused {
            track_id,
            position_ms,
            play_request_id,
            ..
        } => {
            request_state.playing_or_paused(play_request_id);
            let track_uri = track_id.to_string();
            debug!(
                "PlayerEvent::Paused: logical track {} at {}ms",
                track_uri, position_ms
            );
            set_current_track_uri(track_uri);
            IS_PLAYING.store(false, Ordering::SeqCst);
            // Still active when paused - just not playing
            update_position(position_ms);
            // Send playback state update to Swift
            if let Some(notification) =
                capture_local_playback_state(false, position_ms, event_listener_generation)
            {
                applied
                    .notifications
                    .push(PlayerEventNotification::Playback(notification));
            }
        }
        PlayerEvent::PositionChanged { position_ms, .. } => {
            // Periodic position update (every 200ms)
            update_position(position_ms);
        }
        PlayerEvent::Seeked { position_ms, .. } => {
            update_position(position_ms);
        }
        PlayerEvent::PositionCorrection { position_ms, .. } => {
            debug!(
                "[WAKE +{}ms] PositionCorrection event: {}ms",
                elapsed_since_wake_ms(),
                position_ms
            );
            update_position(position_ms);
        }
        PlayerEvent::Stopped {
            play_request_id, ..
        } => {
            request_state.stopped_or_ended(play_request_id);
            // Deliberately does not touch active-device state: playback
            // stopping is not the same as losing the active Connect role.
            // This used to clear it, which fought the cluster-derived value
            // and made the UI think a remote speaker had taken over
            // whenever local playback simply ended.
            //
            // The position *is* reset here, because this event cannot say
            // why playback stopped: `handle_stop` runs for a deactivation,
            // for a queue that has run out, and for `prev` at the first
            // track. Keeping the position for all of them made `next` on the
            // last track leave a resume point mid-track, so pressing play
            // afterwards restarted it there instead of from the beginning.
            // A deactivation saves what it needs in RESUME_POSITION_MS
            // before this arrives.
            IS_PLAYING.store(false, Ordering::SeqCst);
            update_position(0);
        }
        PlayerEvent::EndOfTrack {
            track_id,
            play_request_id,
        } => {
            request_state.stopped_or_ended(play_request_id);
            // Logged with the position it ended at: a natural end and a
            // stream that stopped early are otherwise indistinguishable in
            // the log, because Spirc's auto-advance is silent on success.
            // Without this, "did the track finish or get cut off?" cannot be
            // answered from a log at all.
            debug!(
                "PlayerEvent::EndOfTrack: {} at {}ms",
                track_id,
                POSITION_MS.load(Ordering::SeqCst)
            );
            IS_PLAYING.store(false, Ordering::SeqCst);
            update_position(0);
        }
        PlayerEvent::TrackChanged { audio_item } => {
            let audio_item_uri = audio_item.track_id.to_string();
            let duration_ms = audio_item.duration_ms;
            let logical_track_uri = CURRENT_TRACK_URI
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .clone();
            debug!(
                "TrackChanged event: playable audio item {} ({}ms), logical track {}",
                audio_item_uri,
                duration_ms,
                logical_track_uri.as_deref().unwrap_or("unknown")
            );

            // The AudioItem may be a relinked alternative. Its duration is
            // authoritative for the decoded stream, but its ID must not
            // replace the requested/context track identity.
            CURRENT_DURATION_MS.store(duration_ms, Ordering::SeqCst);
        }
        PlayerEvent::ShuffleChanged { shuffle } => {
            debug!("PlayerEvent::ShuffleChanged: {}", shuffle);
            SHUFFLE_STATE.store(shuffle, Ordering::SeqCst);
            if let Some(notification) = capture_local_playback_state(
                IS_PLAYING.load(Ordering::SeqCst),
                POSITION_MS.load(Ordering::SeqCst),
                event_listener_generation,
            ) {
                applied
                    .notifications
                    .push(PlayerEventNotification::Playback(notification));
            }
        }
        PlayerEvent::RepeatChanged { context, track } => {
            debug!(
                "PlayerEvent::RepeatChanged: context={}, track={}",
                context, track
            );
            REPEAT_CONTEXT_STATE.store(context, Ordering::SeqCst);
            REPEAT_TRACK_STATE.store(track, Ordering::SeqCst);
            if let Some(notification) = capture_local_playback_state(
                IS_PLAYING.load(Ordering::SeqCst),
                POSITION_MS.load(Ordering::SeqCst),
                event_listener_generation,
            ) {
                applied
                    .notifications
                    .push(PlayerEventNotification::Playback(notification));
            }
        }
        PlayerEvent::Loading {
            track_id,
            position_ms,
            play_request_id,
            ..
        } => {
            let track_uri_str = track_id.to_string();
            debug!("Loading event: {} at {}ms", track_uri_str, position_ms);
            if !request_state.loading(play_request_id, track_uri_str.clone()) {
                return;
            }

            // Both, together. The position and the track URI are read as a
            // pair — a resume load seeks `POSITION_MS` within
            // `CURRENT_TRACK_URI` — so leaving the position behind here
            // meant that for the length of a load they described different
            // tracks. A natural transition hides it, because `EndOfTrack`
            // zeroes the position first; a manual `next` does not, and a
            // deactivation landing in that window saved the outgoing track's
            // offset against the incoming track's URI.
            set_current_track_uri(track_uri_str.clone());
            update_position(position_ms);
            // A load supersedes anything saved for an earlier one. Safe
            // against the resume path it serves, which reads the saved point
            // before issuing the load that produces this event — and passes
            // it in as the seek target, so `position_ms` above is that same
            // value. The baton is handed from the saved point to the live
            // one, and a retry after a load that never plays still finds it.
            RESUME_POSITION_MS.store(0, Ordering::SeqCst);
        }
        PlayerEvent::Unavailable {
            track_id,
            play_request_id,
        } => {
            let track_uri = track_id.to_string();
            // The listener identity and the shared logical track must agree before this event
            // can mutate any playback state. Keeping this comparison inside the generation gate
            // closes the race with a newer Loading event.
            let is_current_load = current_track_uri_matches(&track_uri)
                && request_state.matches_current_unavailable(play_request_id, &track_uri);

            // librespot reuses the active Playing/Paused request id when a preload fails. The
            // listener state is armed only by a matching Loading event, so that case is ignored.
            // Consume the listener-owned identity even when the device became inactive between
            // receipt and application. A deactivated local device must still not mutate playback
            // globals or surface an actionable notice for a remote owner.
            if is_current_load
                && request_state.take_matching_unavailable(play_request_id, &track_uri)
                && is_active_device()
            {
                IS_PLAYING.store(false, Ordering::SeqCst);
                update_position(0);
                if let Some(notification) = capture_local_playback_unavailable(
                    POSITION_MS.load(Ordering::SeqCst),
                    event_listener_generation,
                ) {
                    applied
                        .notifications
                        .push(PlayerEventNotification::Playback(notification));
                }
            }
        }
        PlayerEvent::SetQueue {
            context_uri,
            next_tracks,
            prev_tracks,
            ..
        } => {
            debug!(
                "SetQueue event: context={}, next={}, prev={}",
                context_uri,
                next_tracks.len(),
                prev_tracks.len()
            );
            update_current_context_uri(&context_uri);
        }
        // librespot emits SessionDisconnected when the local Connect device
        // becomes INACTIVE — not when the network session fails.
        // SpircTask::handle_disconnect() runs on an explicit Disconnect, on
        // shutdown, and on any cluster update that hands the active role to
        // another device. (This is upstream behavior, not part of our patch.)
        //
        // Treating it as an outage meant an ordinary handoff to a phone or a
        // speaker marked the connection dead and started a reconnect loop
        // against a perfectly healthy session.
        PlayerEvent::SessionDisconnected {
            connection_id,
            user_name: _,
        } => {
            request_state.disconnected();
            // Account identifiers stay out of public logs; connection_id is session context.
            debug!(
                "[WAKE +{}ms] became inactive (SessionDisconnected): connection_id={}, listener_generation={}",
                elapsed_since_wake_ms(),
                connection_id,
                event_listener_generation
            );

            // Capture before clearing: the recovery decision below needs to
            // know what was playing, and set_active_device wipes half of it.
            let intent = RecoveryIntent::capture();
            // Same reason, for the position. librespot calls handle_stop
            // right after emitting this, and the Stopped event that produces
            // resets the live position — so this is the last moment at which
            // where playback stopped is still known to be recoverable.
            //
            // Only when there is something to save. Zero is how this reads
            // as "nothing saved", so writing one would not merely be
            // useless: a second disconnect while already inactive — sleeping
            // after a handoff sends one, since `spotty_playback_disconnect` shuts
            // Spirc down — would overwrite a good point with the zero the
            // first disconnect's `Stopped` had just written.
            if let Some(stopped_at_ms) =
                resume_position_to_save_on_deactivation(POSITION_MS.load(Ordering::SeqCst))
            {
                RESUME_POSITION_MS.store(stopped_at_ms, Ordering::SeqCst);
            }
            if store_active_device(false) {
                if let Some(notification) =
                    capture_connection_state_notification(event_listener_generation)
                {
                    applied
                        .notifications
                        .push(PlayerEventNotification::Connection(notification));
                }
            }

            // Only recover if the transport is genuinely broken. A dead
            // Session here means the Spirc task went down with it (librespot
            // calls handle_disconnect on unexpected shutdown), which the
            // cluster listener may not observe if the dealer stream is still
            // open. A missing Session means some other path already owns the
            // lifecycle, so leave it alone.
            let session_invalid = SESSION
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .as_ref()
                .is_some_and(|s| s.is_invalid());

            if should_recover_after_deactivation(session_invalid, teardown_in_progress()) {
                debug!(
                    "[WAKE +{}ms] Session is invalid at deactivation - recovering",
                    elapsed_since_wake_ms()
                );
                with_connection(|c| {
                    c.session_connected = false;
                    c.last_error = Some("Session invalid".to_string());
                });
                if let Some(notification) =
                    capture_connection_state_notification(event_listener_generation)
                {
                    applied
                        .notifications
                        .push(PlayerEventNotification::Connection(notification));
                }
                applied.recovery = Some(intent);
            } else {
                if let Some(notification) =
                    capture_connection_state_notification(event_listener_generation)
                {
                    applied
                        .notifications
                        .push(PlayerEventNotification::Connection(notification));
                }
            }
        }
        // Emitted when the local Connect device becomes ACTIVE. Carries the
        // session's connection id, but says nothing about network health -
        // the session was already connected before activation.
        PlayerEvent::SessionConnected {
            connection_id,
            user_name: _,
        } => {
            debug!(
                "[WAKE +{}ms] became active (SessionConnected): connection_id={}",
                elapsed_since_wake_ms(),
                connection_id
            );
            if store_active_device(true) {
                if let Some(notification) =
                    capture_connection_state_notification(event_listener_generation)
                {
                    applied
                        .notifications
                        .push(PlayerEventNotification::Connection(notification));
                }
            }

            // Notify connection state change
            if let Some(notification) =
                capture_connection_state_notification(event_listener_generation)
            {
                applied
                    .notifications
                    .push(PlayerEventNotification::Connection(notification));
            }
        }
        PlayerEvent::SessionClientChanged {
            client_id,
            client_name,
            client_brand_name,
            client_model_name,
        } => {
            debug!(
                "SessionClientChanged event: id={}, name={}, brand={}, model={}",
                client_id, client_name, client_brand_name, client_model_name
            );
        }
        _ => {}
    }
}

#[cfg(test)]
mod player_event_pump_policy {
    use super::*;
    use std::sync::atomic::AtomicU8;

    fn sample_event() -> PlayerEvent {
        PlayerEvent::VolumeChanged { volume: 1 }
    }

    #[test]
    fn a_closed_channel_stops_even_if_the_generation_is_current() {
        match player_event_disposition(None, 4, 4) {
            PlayerEventDisposition::ChannelClosed => {}
            other => panic!("expected ChannelClosed, got {other:?}"),
        }
    }

    #[test]
    fn a_closed_channel_stops_even_if_the_generation_is_superseded() {
        match player_event_disposition(None, 3, 4) {
            PlayerEventDisposition::ChannelClosed => {}
            other => panic!("expected ChannelClosed, got {other:?}"),
        }
    }

    #[test]
    fn a_superseded_event_is_ignored() {
        match player_event_disposition(Some(sample_event()), 3, 4) {
            PlayerEventDisposition::IgnoreSuperseded => {}
            other => panic!("expected IgnoreSuperseded, got {other:?}"),
        }
    }

    #[test]
    fn a_current_generation_event_is_applied() {
        match player_event_disposition(Some(sample_event()), 4, 4) {
            PlayerEventDisposition::Apply(PlayerEvent::VolumeChanged { volume: 1 }) => {}
            other => panic!("expected Apply(VolumeChanged), got {other:?}"),
        }
    }

    #[test]
    fn deactivation_saves_a_nonzero_live_position() {
        assert_eq!(resume_position_to_save_on_deactivation(93606), Some(93606));
    }

    #[test]
    fn deactivation_does_not_overwrite_with_a_zero_live_position() {
        assert_eq!(resume_position_to_save_on_deactivation(0), None);
    }

    #[test]
    fn current_loading_request_is_consumed_once_for_unavailable() {
        let mut state = PlayerRequestState::default();
        state.play_request_id_changed(7);
        state.loading(7, "spotify:track:current".to_string());

        assert!(state.matches_current_unavailable(7, "spotify:track:current"));
        assert!(state.take_matching_unavailable(7, "spotify:track:current"));
        assert!(!state.take_matching_unavailable(7, "spotify:track:current"));
    }

    #[test]
    fn stale_unavailable_does_not_consume_the_current_load() {
        let mut state = PlayerRequestState::default();
        state.play_request_id_changed(8);
        state.loading(8, "spotify:track:current".to_string());

        assert!(!state.take_matching_unavailable(7, "spotify:track:stale"));
        assert!(state.take_matching_unavailable(8, "spotify:track:current"));
    }

    #[test]
    fn preload_failure_for_the_same_track_is_not_a_current_load_failure() {
        let mut state = PlayerRequestState::default();
        state.play_request_id_changed(9);
        state.loading(9, "spotify:track:same".to_string());
        // The successful current load moved the listener out of Loading. Librespot's subsequent
        // preload failure reuses this request id, so URI and id alone are insufficient.
        state.playing_or_paused(9);

        assert!(!state.take_matching_unavailable(9, "spotify:track:same"));
    }

    #[test]
    fn inactive_unavailable_consumes_request_without_mutating_playback() {
        let _guard = lock_lifecycle_test_globals();
        let _restore = RestorePlaybackGlobals(capture_playback_globals());
        let uri = "spotify:track:0000000000000000000004";
        set_current_track_uri(uri.to_string());
        store_active_device(false);
        IS_PLAYING.store(true, Ordering::SeqCst);
        POSITION_MS.store(4_321, Ordering::SeqCst);
        let mut state = PlayerRequestState::default();
        state.play_request_id_changed(10);
        state.loading(10, uri.to_string());

        apply_current_generation_event_with_state(
            PlayerEvent::Unavailable {
                play_request_id: 10,
                track_id: parse_spotify_uri(uri).expect("synthetic track URI"),
            },
            1,
            &mut state,
        );

        assert_eq!(state, PlayerRequestState::default());
        assert!(IS_PLAYING.load(Ordering::SeqCst));
        assert_eq!(POSITION_MS.load(Ordering::SeqCst), 4_321);
    }

    #[test]
    fn stale_loading_does_not_disarm_the_newer_request() {
        let mut state = PlayerRequestState::default();
        state.play_request_id_changed(12);
        state.loading(12, "spotify:track:new".to_string());

        state.loading(11, "spotify:track:old".to_string());

        assert!(state.take_matching_unavailable(12, "spotify:track:new"));
    }

    #[test]
    fn deactivation_clears_pending_unavailable_identity() {
        let mut state = PlayerRequestState::default();
        state.play_request_id_changed(13);
        state.loading(13, "spotify:track:inactive".to_string());

        state.disconnected();

        assert!(!state.take_matching_unavailable(13, "spotify:track:inactive"));
    }

    #[test]
    fn mismatched_shared_track_leaves_playback_globals_untouched() {
        let _guard = lock_lifecycle_test_globals();
        let _restore = RestorePlaybackGlobals(capture_playback_globals());
        *CURRENT_TRACK_URI
            .lock()
            .unwrap_or_else(|error| error.into_inner()) =
            Some("spotify:track:0000000000000000000001".to_string());
        IS_PLAYING.store(true, Ordering::SeqCst);
        POSITION_MS.store(4_321, Ordering::SeqCst);
        store_active_device(true);

        let mut state = PlayerRequestState::default();
        state.play_request_id_changed(14);
        state.loading(14, "spotify:track:0000000000000000000002".to_string());
        apply_current_generation_event_with_state(
            PlayerEvent::Unavailable {
                play_request_id: 14,
                track_id: parse_spotify_uri("spotify:track:0000000000000000000002")
                    .expect("synthetic track URI"),
            },
            1,
            &mut state,
        );

        assert!(IS_PLAYING.load(Ordering::SeqCst));
        assert_eq!(POSITION_MS.load(Ordering::SeqCst), 4_321);
        assert!(state.matches_current_unavailable(14, "spotify:track:0000000000000000000002"));
    }

    #[test]
    fn current_unavailable_emits_one_flagged_local_snapshot() {
        static CALLBACK_COUNT: AtomicU32 = AtomicU32::new(0);
        static CALLBACK_UNAVAILABLE: AtomicU8 = AtomicU8::new(0);

        extern "C" fn capture(snapshot: *const SpottyPlaybackSnapshot) {
            let snapshot = unsafe { &*snapshot };
            CALLBACK_COUNT.fetch_add(1, Ordering::SeqCst);
            CALLBACK_UNAVAILABLE.store(snapshot.track_unavailable, Ordering::SeqCst);
        }

        struct RestorePlaybackCallback(Option<PlaybackSnapshotCallback>);

        impl Drop for RestorePlaybackCallback {
            fn drop(&mut self) {
                *CONTROL_CALLBACKS
                    .playback_state
                    .lock()
                    .unwrap_or_else(|error| error.into_inner()) = self.0;
            }
        }

        let _guard = lock_lifecycle_test_globals();
        let _restore_globals = RestorePlaybackGlobals(capture_playback_globals());
        let previous_callback = *CONTROL_CALLBACKS
            .playback_state
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        let _restore_callback = RestorePlaybackCallback(previous_callback);
        *CONTROL_CALLBACKS
            .playback_state
            .lock()
            .unwrap_or_else(|error| error.into_inner()) = Some(capture);
        CALLBACK_COUNT.store(0, Ordering::SeqCst);
        CALLBACK_UNAVAILABLE.store(0, Ordering::SeqCst);

        store_active_device(true);
        let track_uri = "spotify:track:0000000000000000000003";
        let track_id = parse_spotify_uri(track_uri).expect("synthetic track URI");
        let mut state = PlayerRequestState::default();
        apply_current_generation_event_with_state(
            PlayerEvent::PlayRequestIdChanged {
                play_request_id: 15,
            },
            1,
            &mut state,
        );
        apply_current_generation_event_with_state(
            PlayerEvent::Loading {
                play_request_id: 15,
                track_id: track_id.clone(),
                position_ms: 0,
            },
            1,
            &mut state,
        );
        apply_current_generation_event_with_state(
            PlayerEvent::Loading {
                play_request_id: 14,
                track_id: parse_spotify_uri("spotify:track:0000000000000000000004")
                    .expect("synthetic stale track URI"),
                position_ms: 9_999,
            },
            1,
            &mut state,
        );
        assert!(current_track_uri_matches(track_uri));
        assert_eq!(POSITION_MS.load(Ordering::SeqCst), 0);
        apply_current_generation_event_with_state(
            PlayerEvent::Unavailable {
                play_request_id: 15,
                track_id: track_id.clone(),
            },
            1,
            &mut state,
        );
        apply_current_generation_event_with_state(
            PlayerEvent::Unavailable {
                play_request_id: 15,
                track_id,
            },
            1,
            &mut state,
        );

        assert_eq!(CALLBACK_COUNT.load(Ordering::SeqCst), 1);
        assert_eq!(CALLBACK_UNAVAILABLE.load(Ordering::SeqCst), 1);
    }

    fn synthetic_track() -> SpotifyUri {
        parse_spotify_uri("spotify:track:0000000000000000000000").expect("synthetic track URI")
    }

    fn playing_event(position_ms: u32) -> PlayerEvent {
        PlayerEvent::Playing {
            play_request_id: 1,
            track_id: synthetic_track(),
            position_ms,
        }
    }

    fn apply_current_generation_event(event: PlayerEvent, generation: u64) {
        let mut request_state = PlayerRequestState::default();
        apply_current_generation_event_with_state(event, generation, &mut request_state);
    }

    fn apply_current_generation_event_with_state(
        event: PlayerEvent,
        generation: u64,
        request_state: &mut PlayerRequestState,
    ) {
        let previous_generation = SESSION_GENERATION.swap(generation, Ordering::SeqCst);
        apply_player_event(event, generation, request_state);
        SESSION_GENERATION.store(previous_generation, Ordering::SeqCst);
    }

    #[derive(Clone)]
    struct PlaybackGlobals {
        is_playing: bool,
        is_active: bool,
        playing_event_stamp: PlayingEventStamp,
        resume_position_ms: u32,
        position_ms: u32,
        track_uri: Option<String>,
        context_uri: Option<String>,
    }

    fn capture_playback_globals() -> PlaybackGlobals {
        PlaybackGlobals {
            is_playing: IS_PLAYING.load(Ordering::SeqCst),
            is_active: is_active_device(),
            playing_event_stamp: playing_event_stamp(),
            resume_position_ms: RESUME_POSITION_MS.load(Ordering::SeqCst),
            position_ms: POSITION_MS.load(Ordering::SeqCst),
            track_uri: CURRENT_TRACK_URI
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .clone(),
            context_uri: CURRENT_CONTEXT_URI
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .clone(),
        }
    }

    fn restore_playback_globals(snapshot: PlaybackGlobals) {
        IS_PLAYING.store(snapshot.is_playing, Ordering::SeqCst);
        set_active_device(snapshot.is_active);
        replace_playing_event_stamp_for_test(snapshot.playing_event_stamp);
        RESUME_POSITION_MS.store(snapshot.resume_position_ms, Ordering::SeqCst);
        POSITION_MS.store(snapshot.position_ms, Ordering::SeqCst);
        *CURRENT_TRACK_URI.lock().unwrap_or_else(|e| e.into_inner()) = snapshot.track_uri;
        *CURRENT_CONTEXT_URI
            .lock()
            .unwrap_or_else(|e| e.into_inner()) = snapshot.context_uri;
    }

    struct RestorePlaybackGlobals(PlaybackGlobals);

    impl Drop for RestorePlaybackGlobals {
        fn drop(&mut self) {
            restore_playback_globals(self.0.clone());
        }
    }

    #[test]
    fn a_playing_event_is_the_authoritative_playing_transition() {
        let _guard = lock_lifecycle_test_globals();
        let _restore = RestorePlaybackGlobals(capture_playback_globals());
        IS_PLAYING.store(false, Ordering::SeqCst);
        let seq_before = playing_event_stamp().sequence;

        apply_current_generation_event(playing_event(1_250), 1);

        assert!(IS_PLAYING.load(Ordering::SeqCst));
        assert!(playing_event_stamp().sequence > seq_before);
        assert_eq!(POSITION_MS.load(Ordering::SeqCst), 1_250);
        assert_eq!(
            CURRENT_TRACK_URI
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .as_deref(),
            Some("spotify:track:0000000000000000000000")
        );
    }

    #[test]
    fn paused_stopped_and_end_of_track_still_clear_playing() {
        let _guard = lock_lifecycle_test_globals();
        let _restore = RestorePlaybackGlobals(capture_playback_globals());
        let track_id = synthetic_track();

        IS_PLAYING.store(true, Ordering::SeqCst);
        apply_current_generation_event(
            PlayerEvent::Paused {
                play_request_id: 1,
                track_id: track_id.clone(),
                position_ms: 800,
            },
            1,
        );
        assert!(!IS_PLAYING.load(Ordering::SeqCst));
        assert_eq!(POSITION_MS.load(Ordering::SeqCst), 800);

        IS_PLAYING.store(true, Ordering::SeqCst);
        apply_current_generation_event(
            PlayerEvent::Stopped {
                play_request_id: 1,
                track_id: track_id.clone(),
            },
            1,
        );
        assert!(!IS_PLAYING.load(Ordering::SeqCst));

        IS_PLAYING.store(true, Ordering::SeqCst);
        apply_current_generation_event(
            PlayerEvent::EndOfTrack {
                play_request_id: 1,
                track_id,
            },
            1,
        );
        assert!(!IS_PLAYING.load(Ordering::SeqCst));
    }

    #[test]
    fn loading_still_updates_track_position_and_resume_state() {
        let _guard = lock_lifecycle_test_globals();
        let _restore = RestorePlaybackGlobals(capture_playback_globals());
        RESUME_POSITION_MS.store(9_001, Ordering::SeqCst);
        POSITION_MS.store(400, Ordering::SeqCst);
        *CURRENT_TRACK_URI.lock().unwrap_or_else(|e| e.into_inner()) =
            Some("spotify:track:outgoing".to_string());

        let mut request_state = PlayerRequestState::default();
        request_state.play_request_id_changed(1);
        apply_current_generation_event_with_state(
            PlayerEvent::Loading {
                play_request_id: 1,
                track_id: synthetic_track(),
                position_ms: 250,
            },
            1,
            &mut request_state,
        );

        assert_eq!(POSITION_MS.load(Ordering::SeqCst), 250);
        assert_eq!(RESUME_POSITION_MS.load(Ordering::SeqCst), 0);
        assert_eq!(
            CURRENT_TRACK_URI
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .as_deref(),
            Some("spotify:track:0000000000000000000000")
        );
    }

    #[test]
    fn set_queue_still_updates_context() {
        let _guard = lock_lifecycle_test_globals();
        let _restore = RestorePlaybackGlobals(capture_playback_globals());
        *CURRENT_CONTEXT_URI
            .lock()
            .unwrap_or_else(|e| e.into_inner()) = None;

        apply_current_generation_event(
            PlayerEvent::SetQueue {
                context_uri: "spotify:playlist:context".to_string(),
                current_track: None,
                next_tracks: Vec::new(),
                prev_tracks: Vec::new(),
            },
            1,
        );

        assert_eq!(
            CURRENT_CONTEXT_URI
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .as_deref(),
            Some("spotify:playlist:context")
        );
    }

    #[test]
    fn session_connected_and_disconnected_still_update_active_state() {
        let _guard = lock_lifecycle_test_globals();
        let _restore = RestorePlaybackGlobals(capture_playback_globals());
        set_active_device(false);
        apply_current_generation_event(
            PlayerEvent::SessionConnected {
                connection_id: "conn".to_string(),
                user_name: String::new(),
            },
            1,
        );
        assert!(is_active_device());

        POSITION_MS.store(1_200, Ordering::SeqCst);
        apply_current_generation_event(
            PlayerEvent::SessionDisconnected {
                connection_id: "conn".to_string(),
                user_name: String::new(),
            },
            1,
        );
        assert!(!is_active_device());
        assert_eq!(RESUME_POSITION_MS.load(Ordering::SeqCst), 1_200);
    }

    #[test]
    fn cleanup_still_clears_playing() {
        let _guard = lock_lifecycle_test_globals();
        IS_PLAYING.store(true, Ordering::SeqCst);
        spotty_playback_cleanup();
        assert!(!IS_PLAYING.load(Ordering::SeqCst));
    }
}
