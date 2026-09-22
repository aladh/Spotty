#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
source "$project_root/Scripts/swiftpm-env.sh"
if (( $# != 0 )); then
    print -u2 "Usage: $0"
    exit 2
fi

# A separate command-line driver keeps public Accessibility automation out of the app.
driver="$project_root/.build/synthetic-ui-smoke"
xcrun swiftc -parse-as-library -swift-version 6 -warnings-as-errors -sdk "$SDKROOT" \
    "$project_root/Scripts/synthetic_ui_smoke.swift" -o "$driver"
"$driver" --preflight
run_root_file="$(mktemp "$project_root/.build/ui-smoke-run.XXXXXXXX")"
trap 'rm -f "$run_root_file"' EXIT
SPOTTY_BROWSING_RUN_ROOT_FILE="$run_root_file" "$project_root/Scripts/browse-synthetic.sh" --interactive
run_root="$(cat "$run_root_file")"
[[ -d "$run_root" ]] || { print -u2 "Demo launcher did not record its run root"; exit 1; }
# An outer deadline also bounds a stalled Accessibility server or process lookup.
python3 - "$driver" "$run_root" <<'PY'
import json
from pathlib import Path
import subprocess
import sys

try:
    result = subprocess.run([sys.argv[1], sys.argv[2]], timeout=90)
    sys.exit(result.returncode)
except subprocess.TimeoutExpired:
    result = {"passed": False, "category": "timeout", "message": "UI smoke exceeded its 90-second deadline"}
    encoded = json.dumps(result, sort_keys=True)
    (Path(sys.argv[2]) / "ui-smoke.json").write_text(encoded + "\n")
    print(encoded)
    sys.exit(1)
PY
