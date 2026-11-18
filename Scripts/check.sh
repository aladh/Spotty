#!/usr/bin/env bash
set -euo pipefail
cargo_bin=${SPOTTY_CARGO:-cargo}
case "$cargo_bin" in
    /*) ;;
    */*) cargo_bin="$PWD/$cargo_bin" ;;
esac
cd "$(dirname "$0")/../Rune"
case "${SPOTTY_BUILD_CONFIGURATION:-debug}" in
    debug) set -- ;;
    release) set -- --release ;;
    *) echo "SPOTTY_BUILD_CONFIGURATION must be debug or release" >&2; exit 2 ;;
esac
"$cargo_bin" fmt --all --check
"$cargo_bin" test --locked "$@"
"$cargo_bin" build --locked "$@"
