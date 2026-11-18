#!/usr/bin/env bash
set -euo pipefail
project_root=$(cd "$(dirname "$0")/.." && pwd)
binary=${CARGO_TARGET_DIR:-$project_root/Rune/target}/release/spotty-rune
out=$project_root/.build
while [[ $# -gt 0 ]]; do
    case "$1" in
        --binary) binary=$2; shift 2 ;;
        --out-dir) out=$2; shift 2 ;;
        *) echo "Usage: $0 [--binary PATH] [--out-dir DIR]" >&2; exit 2 ;;
    esac
done
mkdir -p "$out"
python3 - "$binary" "$out/size-report.json" <<'PY'
import json
import sys
from pathlib import Path
binary, report = map(Path, sys.argv[1:])
size = binary.stat().st_size
report.write_text(json.dumps({"binary": binary.name, "bytes": size}, indent=2) + "\n")
print(f"{binary}: {size:,} bytes")
PY
