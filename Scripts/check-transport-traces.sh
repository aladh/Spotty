#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
source_sha="$(git rev-parse HEAD)"
engine_sha="$(./Backend/spotty-playback/source-input-digest.sh)" || {
    print -u2 "Unable to identify the engine inputs for transport traces"
    exit 1
}
print "source=$source_sha engine=$engine_sha"
cargo_bin="${SPOTTY_CARGO:-cargo}"
trace_listing="$("$cargo_bin" test --locked --manifest-path Backend/spotty-playback/Cargo.toml --lib transport_trace -- --list)"
for trace in \
    player_event_pump::player_event_pump_policy::transport_trace_play_before_old_paused_and_pause_before_old_playing \
    player_event_pump::player_event_pump_policy::transport_trace_replacement_before_old_position_events \
    player_event_pump::player_event_pump_policy::transport_trace_deactivation_before_stopped \
    observed_resume::tests::transport_trace_recovery_load_requires_fresh_target_and_ownership_evidence; do
    if ! print -r -- "$trace_listing" | grep -Fqx "$trace: test"; then
        print -u2 "Missing required transport trace: $trace"
        exit 1
    fi
done
/usr/bin/time -p "$cargo_bin" test --locked \
    --manifest-path Backend/spotty-playback/Cargo.toml transport_trace -- --nocapture
