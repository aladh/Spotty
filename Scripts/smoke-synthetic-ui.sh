#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
run_root=""
preflight_only=false
while (( $# > 0 )); do
    case "$1" in
        --run-root)
            (( $# >= 2 )) || { print -u2 "--run-root requires an owned Demo run directory"; exit 2; }
            run_root="$2"
            shift
            ;;
        --preflight) preflight_only=true ;;
        *) print -u2 "Usage: $0 [--preflight | --run-root RUN_ROOT]"; exit 2 ;;
    esac
    shift
done
if [[ "$preflight_only" == true && -n "$run_root" ]]; then
    print -u2 "Choose --preflight or --run-root, not both"
    exit 2
fi
if [[ -n "$run_root" && ! -d "$run_root" ]]; then
    print -u2 "The owned Demo run directory does not exist"
    exit 2
fi
source "$project_root/Scripts/swiftpm-env.sh"

# A separate command-line driver keeps public Accessibility automation out of the app.
driver="$project_root/.build/synthetic-ui-smoke"
xcrun swiftc -parse-as-library -swift-version 6 -warnings-as-errors -sdk "$SDKROOT" \
    "$project_root/Scripts/synthetic_ui_smoke.swift" -o "$driver"
"$driver" --preflight
[[ "$preflight_only" == false ]] || exit 0
if [[ -z "$run_root" ]]; then
    run_root_file="$(mktemp "$project_root/.build/ui-smoke-run.XXXXXXXX")"
    trap 'rm -f "$run_root_file"' EXIT
    SPOTTY_BROWSING_RUN_ROOT_FILE="$run_root_file" "$project_root/Scripts/browse-synthetic.sh" --interactive \
        "$project_root/Tests/BrowsingHarness/Scenarios/gui-shell.json"
    run_root="$(cat "$run_root_file")"
    [[ -d "$run_root" ]] || { print -u2 "Demo launcher did not record its run root"; exit 1; }
fi
# Exactly one driver attempt; preserve its partial checkpoints if an AX server stalls.
python3 - "$driver" "$run_root" <<'PY'
import json
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[2]).resolve()
evidence = root / "ui-smoke.json"
if evidence.exists():
    sys.exit("This Demo run already has UI smoke evidence; use a fresh run")
try:
    result = subprocess.run([sys.argv[1], str(root)], timeout=135)
    sys.exit(result.returncode)
except subprocess.TimeoutExpired:
    result = {}
    if evidence.exists():
        try:
            prior = json.loads(evidence.read_text())
            if not isinstance(prior, dict):
                raise ValueError("Partial UI smoke evidence is not an object")
            result = prior
        except (OSError, ValueError):
            # Keep malformed partial bytes for diagnosis before writing a bounded outcome.
            evidence.rename(root / "ui-smoke.partial.json")
    result.update(passed=False, category="timeout", message="UI smoke exceeded its 135-second outer deadline")
    encoded = json.dumps(result, sort_keys=True)
    temporary = root / "ui-smoke.timeout.tmp"
    temporary.write_text(encoded + "\n")
    temporary.replace(evidence)
    print(encoded)
    sys.exit(1)
PY
