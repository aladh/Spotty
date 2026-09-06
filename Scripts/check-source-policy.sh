#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
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

# Presence rules inspect a syntax tree; a missing owner file must not silently skip them.
for owner in Sources/Spotty/SpottyApp.swift \
    Sources/Spotty/Spotify/PlaybackCore.swift \
    Sources/Spotty/Spotify/RustPlaybackEngine.swift; do
    test -f "$owner" || { echo "Missing policy owner: $owner" >&2; exit 1; }
done

"$ast_grep" test --config sgconfig.yml --skip-snapshot-tests
python3 -B -m unittest discover -s Scripts -p test_source_policy.py
"$ast_grep" scan --config sgconfig.yml Sources
