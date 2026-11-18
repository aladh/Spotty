#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../Rune"
cargo_bin=${SPOTTY_CARGO:-cargo}
case "${SPOTTY_BUILD_CONFIGURATION:-debug}" in
    debug) set -- ;;
    release) set -- --release ;;
    *) echo "SPOTTY_BUILD_CONFIGURATION must be debug or release" >&2; exit 2 ;;
esac
"$cargo_bin" fmt --all --check
"$cargo_bin" test --locked "$@"
"$cargo_bin" build --locked "$@"
