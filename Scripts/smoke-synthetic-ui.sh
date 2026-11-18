#!/usr/bin/env bash
set -euo pipefail
project_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_root/Rune"
cargo test --locked --bin spotty-rune 'tests::'
exec "$project_root/Scripts/browse-synthetic.sh" "$@"
