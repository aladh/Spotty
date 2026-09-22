#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
source "$project_root/Scripts/swiftpm-env.sh"
source "$project_root/Scripts/embed-sparkle.sh"
cd "$project_root"
automated=true
profile=false
optimized=false
scenario_id=""
while (( $# > 0 )); do
    case "$1" in
        --profile) profile=true ;;
        --interactive) automated=false ;;
        --optimized) optimized=true ;;
        --scenario)
            (( $# >= 2 )) || { print -u2 "--scenario requires a stable scenario ID"; exit 2; }
            scenario_id="$2"
            shift
            ;;
        --list)
            python3 "$project_root/Scripts/acceptance_scenarios.py" list
            exit
            ;;
        *) break ;;
    esac
    shift
done
if (( $# > 1 )); then
    print -u2 "Usage: $0 [--optimized] [--profile] [--interactive] [--scenario ID | scenario.json]"
    exit 2
fi
default_scenario="$project_root/Tests/BrowsingHarness/scenario.json"
if [[ "$automated" == false && "$profile" == false ]]; then
    default_scenario="$project_root/Tests/BrowsingHarness/demo.json"
fi
scenario="${1:-$default_scenario}"
if [[ -n "$scenario_id" && $# != 0 ]]; then
    print -u2 "Choose a named scenario or a workload path, not both"
    exit 2
fi
mkdir -p "$project_root/.build/browsing-runs"
run_root="$(mktemp -d "$project_root/.build/browsing-runs/run.XXXXXXXX")"
if [[ -n "$scenario_id" ]]; then
    scenario="$run_root/scenario.json"
    python3 "$project_root/Scripts/acceptance_scenarios.py" prepare-demo "$scenario_id" --output "$scenario"
fi
[[ -f "$scenario" ]] || { print -u2 "Scenario file does not exist"; exit 2; }
# Keep legacy report.json and add evidence even when launch or workload fails.
TRAPEXIT() {
    local result=$?
    if [[ "$automated" == true || "$profile" == true ]]; then
        python3 "$project_root/Scripts/acceptance_scenarios.py" demo-evidence \
            --output "$run_root" --workload "$scenario" --exit-code "$result" || return 1
    fi
    return "$result"
}
if [[ "$profile" == true ]]; then
    python3 "$project_root/Scripts/profile_synthetic.py" --preflight "$run_root"
fi

signing_identity="${SPOTTY_DEVELOPMENT_SIGNING_IDENTITY:-${SPOTTY_SIGNING_IDENTITY:-}}"
if [[ -z "$signing_identity" ]]; then
    identities="$(security find-identity -p codesigning -v 2>/dev/null | sed -nE 's/^[[:space:]]*[0-9]+\) [[:xdigit:]]+ "(Apple Development:[^"]+)"$/\1/p')"
    identity_count="$(print -r -- "$identities" | sed '/^$/d' | wc -l | tr -d ' ')"
    if [[ "$identity_count" != 1 ]]; then
        print -u2 "Set SPOTTY_DEVELOPMENT_SIGNING_IDENTITY to an existing Apple Development identity (see docs/development/signing.md)."
        exit 1
    fi
    signing_identity="$identities"
fi

configuration=debug
scratch="$project_root/.build"
build_arguments=(--disable-sandbox --sdk "$SDKROOT" --configuration debug)
if [[ "$optimized" == true ]]; then
    configuration=release
    scratch="$project_root/.build/browsing-optimized"
    # Only the opt-in Demo build gets testability. Keep these artifacts outside shipping builds.
    build_arguments=(--disable-sandbox --sdk "$SDKROOT" --configuration release --scratch-path "$scratch"
        -Xswiftc -O -Xswiftc -enable-testing -Xswiftc -DSPOTTY_BROWSING_OPTIMIZED)
fi
python3 "$project_root/Scripts/browsing_provenance.py" snapshot "$project_root" "$run_root"
SPOTTY_BUILD_BROWSING_HARNESS=1 swift build "${build_arguments[@]}" \
    --product SpottyBrowsingHarness "${spotty_swiftc_warnings_as_errors[@]}"
binary_dir="$(SPOTTY_BUILD_BROWSING_HARNESS=1 swift build "${build_arguments[@]}" --show-bin-path)"
app="$run_root/Spotty Demo.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/SpottyBrowsingHarness" "$app/Contents/MacOS/SpottyDemo"
cp -R "$binary_dir/Spotty_SpottyBrowsingSupport.bundle" "$app/Contents/Resources/"
icon_root="$project_root/Tests/BrowsingHarness/Icon"
xcrun actool --compile "$app/Contents/Resources" --platform macosx \
    --minimum-deployment-target 15.0 --app-icon SpottyDemo \
    --output-partial-info-plist "$run_root/icon-info.plist" "$icon_root/SpottyDemo.icon"
cp "$icon_root/SpottyDemo.icns" "$app/Contents/Resources/"
cp "$scenario" "$app/Contents/Resources/scenario.json"

# A stable developer identity preserves macOS permissions; demo state is separate from live Spotty.
# Only this run's artifacts are writable outside its sandbox container; sockets remain denied.
python3 - "$run_root" "$app" <<'PY'
from pathlib import Path
import plistlib
import sys

root, app = map(Path, sys.argv[1:3])
identifier = "dev.spotty.demo"
plist = {
    "CFBundleIdentifier": identifier, "CFBundleExecutable": "SpottyDemo",
    "CFBundleName": "Spotty Demo", "CFBundleDisplayName": "Spotty Demo", "CFBundlePackageType": "APPL",
    "CFBundleIconName": "SpottyDemo", "CFBundleIconFile": "SpottyDemo",
    "LSMinimumSystemVersion": "15.0", "NSPrincipalClass": "NSApplication",
}
(app / "Contents/Info.plist").write_bytes(plistlib.dumps(plist))
(root / "entitlements.plist").write_bytes(plistlib.dumps({
    "com.apple.security.app-sandbox": True,
    "com.apple.security.temporary-exception.files.absolute-path.read-write": [str(root) + "/"],
}))
PY
python3 "$project_root/Scripts/browsing_provenance.py" launch "$project_root" "$run_root" \
    --scratch "$scratch" --app "$app" --configuration "$configuration" \
    --automated "$automated" --profile "$profile"
spotty_embed_sparkle "$app" "$signing_identity" --scratch-path "$scratch" --timestamp=none
/usr/bin/codesign --force --options runtime --timestamp=none --sign "$signing_identity" --entitlements "$run_root/entitlements.plist" "$app"
/usr/bin/codesign --verify --strict "$app"
/usr/bin/codesign --verify --strict -R '=anchor apple generic' "$app"
signing_details="$(/usr/bin/codesign --display --verbose=4 "$app" 2>&1)"
if ! print -r -- "$signing_details" | rg -q '^TeamIdentifier=[A-Z0-9]+$'; then
    print -u2 "Demo signing requires an Apple-issued identity with a stable Team ID"
    exit 1
fi
# Validate first, then replace only this demo's stable install location.
installed_app="$project_root/.build/Spotty Demo.app"
python3 - "$project_root/Scripts" "$installed_app/Contents/MacOS/SpottyDemo" <<'PYSTOP'
from pathlib import Path
import sys
sys.path.insert(0, sys.argv[1])
from browsing_process import capture, executable_path, process_ids, terminate

expected = str(Path(sys.argv[2]).resolve())
for pid in process_ids():
    try:
        if executable_path(pid) != expected:
            continue
        record = capture(pid, expected)
    except (OSError, ValueError):
        continue
    terminate(record)
PYSTOP
if [[ -d "$installed_app" ]]; then
    mv "$installed_app" "$run_root/previous-demo.app"
fi
if ! mv "$app" "$installed_app"; then
    if [[ -d "$run_root/previous-demo.app" ]]; then
        mv "$run_root/previous-demo.app" "$installed_app"
    fi
    exit 1
fi
app="$installed_app"
/usr/bin/open -n "$app"
python3 "$project_root/Scripts/browsing_process.py" discover "$run_root" "$app/Contents/MacOS/SpottyDemo"
if [[ -n "${SPOTTY_BROWSING_RUN_ROOT_FILE:-}" ]]; then
    print -r -- "$run_root" > "$SPOTTY_BROWSING_RUN_ROOT_FILE"
fi
print "Synthetic browsing launched: $app"
if [[ "$profile" == true ]]; then
    if [[ "$automated" == false ]]; then
        print "Prepare the Demo window, then choose Demo > Run Measurement."
    fi
    python3 "$project_root/Scripts/profile_synthetic.py" "$run_root"
fi
if [[ "$automated" == true || "$profile" == true ]]; then
    print "Report: $run_root/report.json"
    python3 - "$run_root/report.json" "$project_root/Scripts" <<'PYWAIT'
import json
from pathlib import Path
import sys
import time
sys.path.insert(0, sys.argv[2])
from browsing_process import load_record, matches

report = Path(sys.argv[1])
started = time.monotonic()
owned = load_record(report.parent)
# Covers the maximum validated scenario, including bounded view-readiness waits.
while not report.exists():
    elapsed = time.monotonic() - started
    if elapsed > 600:
        sys.exit("Timed out waiting for the demo workload report")
    if elapsed > 5 and not matches(owned):
        sys.exit("The demo exited without a workload report")
    time.sleep(0.25)
result = json.loads(report.read_text())
if result.get("passed") is not True:
    sys.exit(result.get("failure") or "The demo workload failed")
print(f"Passed {len(result['samples'])} browsing checkpoints")
PYWAIT
else
    print "Interactive demo; run artifacts: $run_root"
fi

if [[ "$profile" == true ]]; then
    print "Local Instruments trace: $run_root/animation.trace"
fi
