#!/usr/bin/env bash
set -euo pipefail
project_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_root/Rune"
interactive=false
profile=dev
while [[ $# -gt 0 ]]; do
    case "$1" in
        --interactive) interactive=true; shift ;;
        --optimized) profile=release; shift ;;
        *) break ;;
    esac
done
mkdir -p "$project_root/.build/browsing-runs"
result=$(mktemp -d "$project_root/.build/browsing-runs/run.XXXXXXXX")
binary=$(cargo build --locked --profile "$profile" --message-format=json-render-diagnostics | python3 -c '
import json, sys
for line in sys.stdin:
    record = json.loads(line)
    if record.get("target", {}).get("name") == "spotty-rune" and record.get("executable"):
        print(record["executable"])
')
test -x "$binary"
args=(--demo)
if ! "$interactive"; then
    args+=(--scene reference --size 1720x1078 --snap "$result/reference.png" --tree "$result/reference.json")
fi
if [[ "$(uname -s)" == Darwin ]]; then
    identity="${SPOTTY_DEVELOPMENT_SIGNING_IDENTITY:-${SPOTTY_SIGNING_IDENTITY:-}}"
    if [[ -z "$identity" ]]; then
        identity=$(security find-identity -p codesigning -v | sed -nE 's/^[[:space:]]*[0-9]+\) [[:xdigit:]]+ "(Apple Development:[^"]+)"$/\1/p')
        if [[ -z "$identity" || "$identity" == *$'\n'* ]]; then
            echo "Select one Apple Development identity in SPOTTY_DEVELOPMENT_SIGNING_IDENTITY." >&2
            exit 1
        fi
    fi
    app="$result/Spotty Demo.app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$binary" "$app/Contents/MacOS/SpottyDemo"
    cp "$project_root/Tests/BrowsingHarness/Icon/SpottyDemo.icns" "$app/Contents/Resources/"
    python3 - "$result" "$app" <<'PY'
import plistlib, sys
from pathlib import Path
root, app = map(Path, sys.argv[1:])
info = dict(CFBundleIdentifier="dev.spotty.demo", CFBundleExecutable="SpottyDemo",
            CFBundleName="Spotty Demo", CFBundleDisplayName="Spotty Demo", CFBundlePackageType="APPL",
            CFBundleIconFile="SpottyDemo", LSMinimumSystemVersion="27.0", NSPrincipalClass="NSApplication")
(app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
(root / "entitlements.plist").write_bytes(plistlib.dumps({
    "com.apple.security.app-sandbox": True,
    "com.apple.security.temporary-exception.files.absolute-path.read-write": [str(root.resolve()) + "/"],
}))
PY
    codesign --force --options runtime --timestamp=none --sign "$identity" --entitlements "$result/entitlements.plist" "$app"
    codesign --verify --strict -R '=anchor apple generic' "$app"
    signing=$(codesign --display --verbose=4 "$app" 2>&1)
    grep -Eq '^TeamIdentifier=[A-Z0-9]+$' <<< "$signing"
    "$app/Contents/MacOS/SpottyDemo" "${args[@]}" "$@"
else
    # The synthetic process may talk to its local display server. Block Internet sockets for
    # the application and any children, and keep its writable state in its own temporary home.
    mkdir -m 700 "$result/home"
    HOME="$result/home" XDG_DATA_HOME="$result/home/data" XDG_CONFIG_HOME="$result/home/config" \
        XDG_CACHE_HOME="$result/home/cache" python3 "$project_root/Scripts/run-demo-linux.py" "$binary" "${args[@]}" "$@"
fi
if ! "$interactive"; then
    python3 - "$result/reference.json" <<'PY'
import json, sys
from pathlib import Path
tree = json.loads(Path(sys.argv[1]).read_bytes())
if tree["warnings"]:
    raise SystemExit(tree["warnings"])
PY
fi
echo "$result"
