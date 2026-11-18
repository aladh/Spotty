#!/usr/bin/env bash
set -euo pipefail
project_root=$(cd "$(dirname "$0")/.." && pwd)
binary=${CARGO_TARGET_DIR:-$project_root/Rune/target}/release/spotty-rune
out=$project_root/.build
while [[ $# -gt 0 ]]; do
    case "$1" in
        --binary|--out-dir)
            if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
                echo "$1 requires a path" >&2
                exit 2
            fi
            if [[ "$1" == --binary ]]; then binary=$2; else out=$2; fi
            shift 2
            ;;
        *) echo "Usage: $0 [--binary PATH] [--out-dir DIR]" >&2; exit 2 ;;
    esac
done
mkdir -p "$out"
python3 - "$binary" "$out/size-report.json" <<'PY'
import json
import sys
from pathlib import Path
binary, report = map(Path, sys.argv[1:])
if not binary.is_file():
    raise SystemExit(f"Expected a regular binary file: {binary}")
size = binary.stat().st_size
report.write_text(json.dumps({"binary": binary.name, "bytes": size}, indent=2) + "\n")
print(f"{binary}: {size:,} bytes")
PY
