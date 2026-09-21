#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
print "source=$(git rev-parse HEAD) engine=$($project_root/Backend/spotty-playback/source-input-digest.sh)"
/usr/bin/time -p "${SPOTTY_CARGO:-cargo}" test --locked \
    --manifest-path Backend/spotty-playback/Cargo.toml transport_trace -- --nocapture
