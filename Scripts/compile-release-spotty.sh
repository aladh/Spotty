#!/usr/bin/env bash
set -euo pipefail
cargo_bin=${SPOTTY_CARGO:-cargo}
case "$cargo_bin" in
    /*) ;;
    */*) cargo_bin="$PWD/$cargo_bin" ;;
esac
cd "$(dirname "$0")/../Rune"
exec "$cargo_bin" build --locked --release
