#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../Rune"
exec "${SPOTTY_CARGO:-cargo}" build --locked --release
