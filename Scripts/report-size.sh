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
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

binary, report = map(Path, sys.argv[1:])
if not binary.is_file():
    raise SystemExit(f"Expected a regular binary file: {binary}")
size = binary.stat().st_size
segments = {name: None for name in ("text_bytes", "data_bytes", "linkedit_bytes")}
labels = dict(zip(segments, ("__TEXT", "__DATA", "__LINKEDIT")))
if tool := shutil.which("size"):
    details = subprocess.run([tool, "-m", str(binary)], capture_output=True, text=True, check=False)
    if details.returncode == 0:
        values = dict(re.findall(r"^[ \t]*Segment (__TEXT|__DATA|__LINKEDIT):[ \t]+(\d+)\b", details.stdout, re.MULTILINE))
        if values.keys() == set(labels.values()):
            segments = {key: int(values[label]) for key, label in labels.items()}
available = all(value is not None for value in segments.values())
body = [
    "## Release build size", "", "| Metric | Value |", "| --- | ---: |",
    f"| App binary | {size} bytes ({size / 2**20:.2f} MiB) |",
]
if available:
    body.extend(f"| Binary {labels[key]} | {value} bytes ({value / 2**20:.2f} MiB) |"
                for key, value in segments.items())
else:
    body.append("| Binary segments | unavailable |")
summary = "\n".join(body) + "\n"
print(summary, end="")
if destination := os.environ.get("GITHUB_STEP_SUMMARY"):
    with Path(destination).open("a", encoding="utf-8") as output:
        output.write(summary)
report.write_text(json.dumps({
    "schema_version": 2,
    "binary_path": str(binary),
    "binary_bytes": size,
    "binary_mib": round(size / 2**20, 2),
    "binary_segments": {"available": available, **segments},
}, indent=2) + "\n", encoding="utf-8")
PY
