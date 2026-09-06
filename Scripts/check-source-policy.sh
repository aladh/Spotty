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

# Required policy owners must exist and contain content, even when compiler jobs are skipped.
for owner in README.md SECURITY.md CONTRIBUTING.md Sources/Spotty/SpottyApp.swift \
    Sources/Spotty/Spotify/PlaybackCore.swift \
    Sources/Spotty/Spotify/KeychainManager.swift \
    Sources/Spotty/Spotify/RustPlaybackEngine.swift \
    Backend/spotty-playback/src/player_event_pump.rs; do
    [[ -f "$owner" && -s "$owner" ]] || { echo "Missing or empty policy owner: $owner" >&2; exit 1; }
done

if grep -nE "MockCatalog|PlaybackController|demo catalog" \
    "README.md"; then
    echo "Mock catalog references remain"
    exit 1
fi

if grep -nE 'security@example\.com|replace this placeholder' \
    "README.md" \
    "SECURITY.md" \
    "CONTRIBUTING.md"; then
    echo "A public-facing security-contact placeholder remains"
    exit 1
fi

"$ast_grep" test --config sgconfig.yml --skip-snapshot-tests
python3 -B -m unittest discover -s Scripts -p 'test_*policy.py'
# CI's ast-grep action already scans production and emits GitHub annotations.
if [[ "${1:-}" != --test-only ]]; then
    "$ast_grep" scan --config sgconfig.yml Sources Backend/spotty-playback/src Scripts .github/workflows
fi
