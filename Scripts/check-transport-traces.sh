#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../Rune"
cargo_bin=${SPOTTY_CARGO:-cargo}
trace_listing=$("$cargo_bin" test --locked --bin spotty-rune transport_trace -- --list)
for trace in \
    player_event_pump::player_event_pump_policy::transport_trace_play_before_old_paused_and_pause_before_old_playing \
    player_event_pump::player_event_pump_policy::transport_trace_replacement_before_old_position_events \
    player_event_pump::player_event_pump_policy::transport_trace_deactivation_before_stopped \
    observed_resume::tests::transport_trace_recovery_load_requires_fresh_target_and_ownership_evidence; do
    if ! grep -Fxq "playback::$trace: test" <<< "$trace_listing"; then
        echo "Missing required transport trace: playback::$trace" >&2
        exit 1
    fi
done
exec "$cargo_bin" test --locked --bin spotty-rune transport_trace -- --nocapture
