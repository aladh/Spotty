#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
source "$project_root/Scripts/swiftpm-env.sh"
cd "$project_root"
automated=true
if [[ "${1:-}" == "--interactive" ]]; then
    automated=false
    shift
fi
if (( $# > 1 )); then
    print -u2 "Usage: $0 [--interactive] [scenario.json]"
    exit 2
fi
scenario="${1:-$project_root/Tests/BrowsingHarness/scenario.json}"
[[ -f "$scenario" ]] || { print -u2 "Scenario file does not exist"; exit 2; }

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

SPOTTY_BUILD_BROWSING_HARNESS=1 swift build --disable-sandbox --configuration debug \
    --product SpottyBrowsingHarness "${spotty_swiftc_warnings_as_errors[@]}"
binary_dir="$(SPOTTY_BUILD_BROWSING_HARNESS=1 swift build --disable-sandbox --configuration debug --show-bin-path)"
mkdir -p "$project_root/.build/browsing-runs"
run_root="$(mktemp -d "$project_root/.build/browsing-runs/run.XXXXXXXX")"
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
python3 - "$run_root" "$app" "$automated" <<'PY'
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
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
launch = {
    "runRoot": str(root), "automated": sys.argv[3] == "true",
    "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
    "diffSHA256": hashlib.sha256(subprocess.check_output(["git", "diff", "HEAD", "--"])).hexdigest(),
}
(app / "Contents/Resources/launch.json").write_text(json.dumps(launch))
PY
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
pkill -x SpottyDemo >/dev/null 2>&1 || true
for _ in {1..50}; do
    pgrep -x SpottyDemo >/dev/null || break
    sleep 0.1
done
if pgrep -x SpottyDemo >/dev/null; then
    print -u2 "The demo did not terminate; leaving the installed bundle in place"
    exit 1
fi
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
print "Synthetic browsing launched: $app"
if [[ "$automated" == true ]]; then
    print "Report: $run_root/report.json"
    python3 - "$run_root/report.json" <<'PYWAIT'
import json
from pathlib import Path
import subprocess
import sys
import time

report = Path(sys.argv[1])
started = time.monotonic()
# Covers the maximum validated scenario, including bounded view-readiness waits.
while not report.exists():
    elapsed = time.monotonic() - started
    if elapsed > 600:
        sys.exit("Timed out waiting for the demo workload report")
    if elapsed > 5 and subprocess.run(["pgrep", "-x", "SpottyDemo"], stdout=subprocess.DEVNULL).returncode:
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
