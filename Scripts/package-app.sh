#!/bin/zsh
set -euo pipefail
root=${0:A:h:h}
export SPOTTY_APP_PATH="${SPOTTY_APP_PATH:-$root/Spotty.app}"
exec "$root/Rune/package-macos.sh" "${1:---debug}"
