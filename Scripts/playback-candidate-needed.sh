#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

candidate_paths() {
    ./Backend/spotty-playback/source-input-digest.sh --print-inputs || return 1
    # Whole directories catch deletions; infrastructure changes revalidate candidate creation.
    printf '%s\n' Backend/spotty-playback/src Scripts/playback-license-overrides \
        Backend/spotty-playback/validate-xcframework.sh \
        Scripts/ci_playback_definition.py Scripts/playback-candidate-needed.sh
}

if [[ "${1:-}" == --print-paths && $# == 1 ]]; then
    candidate_paths
    exit 0
elif (( $# != 0 )); then
    echo "Usage: $0 [--print-paths]" >&2
    exit 2
fi

digest="$(./Backend/spotty-playback/source-input-digest.sh)"
candidate_needed=true
# Compare this change, not the app's independently selected engine release.
if [[ -n "${INPUT_BASE_SHA:-}" && "$INPUT_BASE_SHA" != 0000000000000000000000000000000000000000 ]]; then
    if [[ ! "$INPUT_BASE_SHA" =~ ^[0-9a-f]{40}$ ]]; then
        echo "Candidate selection requires a full hexadecimal base SHA" >&2
        exit 1
    fi
    if ! git fetch --no-tags --depth=1 origin "$INPUT_BASE_SHA"; then
        echo "Could not fetch the base commit for candidate selection" >&2
        exit 1
    fi
    input_list="$(candidate_paths)"
    paths=()
    while IFS= read -r path; do paths+=("$path"); done <<< "$input_list"
    if git diff --quiet "$INPUT_BASE_SHA" HEAD -- "${paths[@]}"; then
        # Changes to Swift checks or the Linux image need no new engine archive, but changes
        # to producer steps, source policies, or workflow trust still revalidate production.
        if python3 -B - "$INPUT_BASE_SHA" <<'PYTHON'
import subprocess
import sys
from pathlib import Path
sys.path.insert(0, "Scripts")
from ci_playback_definition import producer_definition
try:
    base = subprocess.check_output(["git", "show", f"{sys.argv[1]}:.github/workflows/ci.yml"], stderr=subprocess.DEVNULL)
    current = Path(".github/workflows/ci.yml").read_bytes()
    unchanged = producer_definition(base) == producer_definition(current)
except (OSError, UnicodeError, ValueError, subprocess.CalledProcessError):
    unchanged = False  # Unknown layout or missing history requires a candidate.
sys.exit(0 if unchanged else 1)
PYTHON
        then
            candidate_needed=false
        fi
    else
        diff_status=$?
        if [[ "$diff_status" != 1 ]]; then
            echo "Could not compare engine inputs with the candidate base" >&2
            exit "$diff_status"
        fi
    fi
fi
echo "PLAYBACK_INPUT_DIGEST=$digest" >> "$GITHUB_ENV"
echo "candidate_needed=$candidate_needed" >> "$GITHUB_OUTPUT"
echo "Playback candidate needed: $candidate_needed"
