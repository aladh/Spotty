#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
if (( $# > 1 )) || [[ "${1:-}" != "" && "${1:-}" != --test-only ]]; then
    echo "Usage: $0 [--test-only]" >&2
    exit 2
fi
ast_grep="${SPOTTY_AST_GREP:-ast-grep}"
expected_version="$(cat Scripts/ast-grep/version)"
if ! command -v "$ast_grep" >/dev/null 2>&1; then
    echo "Install ast-grep $expected_version (see docs/development/verification.md)." >&2
    exit 1
fi
if [[ "$("$ast_grep" --version)" != "ast-grep $expected_version" ]]; then
    echo "Source policies require ast-grep $expected_version; set SPOTTY_AST_GREP to that executable." >&2
    exit 1
fi
export SPOTTY_AST_GREP="$ast_grep"

# Presence rules inspect a syntax tree; missing or empty owner files must not silently skip them.
for owner in Sources/Spotty/SpottyApp.swift \
    Sources/Spotty/Spotify/PlaybackCore.swift \
    Sources/Spotty/Spotify/KeychainManager.swift \
    Sources/Spotty/Spotify/RustPlaybackEngine.swift \
    Backend/spotty-playback/src/player_event_pump.rs; do
    [[ -f "$owner" && -s "$owner" ]] || { echo "Missing or empty policy owner: $owner" >&2; exit 1; }
done

"$ast_grep" test --config sgconfig.yml --skip-snapshot-tests
python3 -B -m unittest discover -s Scripts -p 'test_*policy.py'
# CI's ast-grep action already scans production and emits GitHub annotations.
if [[ "${1:-}" != --test-only ]]; then
    "$ast_grep" scan --config sgconfig.yml Sources Backend/spotty-playback/src Scripts .github/workflows
fi
