#!/usr/bin/env bash
set -euo pipefail
project_root=$(cd "$(dirname "$0")/.." && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/spotty-clean.XXXXXXXX")
trap 'rm -rf -- "$build_dir"' EXIT
export CARGO_TARGET_DIR="$build_dir"
SPOTTY_BUILD_CONFIGURATION=debug "$project_root/Scripts/check.sh"
SPOTTY_BUILD_CONFIGURATION=release "$project_root/Scripts/check.sh"
