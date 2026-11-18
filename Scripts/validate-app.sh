#!/bin/zsh
set -euo pipefail

validation_mode="${1:---local}"
app_path="${2:-${0:A:h:h}/Spotty.app}"

case "$validation_mode" in
    --local|local)
        require_distribution=false
        require_development_signature=false
        ;;
    --development-signed|development-signed)
        require_distribution=false
        require_development_signature=true
        ;;
    --distribution|distribution)
        require_distribution=true
        require_development_signature=true
        ;;
    *)
        print -u2 "usage: $0 [--local|--development-signed|--distribution] [path-to-app]"
        exit 2
        ;;
esac

if [[ ! -d "$app_path" ]]; then
    print -u2 "Missing app bundle: $app_path"
    exit 1
fi

info_plist="$app_path/Contents/Info.plist"
app_binary="$app_path/Contents/MacOS/Spotty"
third_party_notices="$app_path/Contents/Resources/ThirdPartyNotices.md"
native_icon_catalog="$app_path/Contents/Resources/Assets.car"
legacy_icon="$app_path/Contents/Resources/Spotty.icns"

plutil -lint "$info_plist"
if [[ ! -f "$app_path/Contents/PkgInfo" ]]; then
    print -u2 "Missing app bundle PkgInfo: $app_path/Contents/PkgInfo"
    exit 1
fi
for required_key in \
    CFBundleIdentifier \
    CFBundleExecutable \
    CFBundleIconName \
    CFBundleIconFile \
    CFBundleShortVersionString \
    CFBundleVersion \
    LSMinimumSystemVersion; do
    /usr/libexec/PlistBuddy -c "Print :$required_key" "$info_plist" >/dev/null
done

if [[ ! -x "$app_binary" ]]; then
    print -u2 "Missing executable app binary: $app_binary"
    exit 1
fi
if [[ ! -s "$third_party_notices" ]]; then
    print -u2 "Missing third-party license notices: $third_party_notices"
    exit 1
fi
if [[ ! -s "$native_icon_catalog" ]]; then
    print -u2 "Missing compiled native app icon catalog: $native_icon_catalog"
    exit 1
fi
if ! /usr/bin/assetutil --info "$native_icon_catalog" \
    | /usr/bin/jq -e 'any(.[]; .AssetType == "IconImageStack" and .Name == "Spotty")' >/dev/null; then
    print -u2 "App icon catalog must contain the native Spotty icon stack"
    exit 1
fi
if [[ ! -s "$legacy_icon" ]]; then
    print -u2 "Missing legacy app icon file: $legacy_icon"
    exit 1
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$info_plist")" != "Spotty" ]]; then
    print -u2 "App bundle must select the native Spotty icon with CFBundleIconName=Spotty"
    exit 1
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$info_plist")" != "Spotty" ]]; then
    print -u2 "App bundle must retain the Spotty.icns resource with CFBundleIconFile=Spotty"
    exit 1
fi

sparkle_framework="$app_path/Contents/Frameworks/Sparkle.framework"
python3 - "$info_plist" "${0:A:h:h}/Packaging/Info.plist" "$sparkle_framework" "${0:A:h:h}/Rune/configure-updates.py" <<'PYTHON'
import base64
import os
import pathlib
import plistlib
import runpy
import sys

plist, legacy, framework, config = map(pathlib.Path, sys.argv[1:])
info = plistlib.loads(plist.read_bytes())
upstream = plistlib.loads(legacy.read_bytes())
if info.get("SpottyRuneUpdateChannel") == "rune":
    try:
        runpy.run_path(str(config))["validate_update_feed"](info.get("SUFeedURL", ""), upstream["SUFeedURL"])
        key = base64.b64decode(info.get("SUPublicEDKey", ""), validate=True)
    except (TypeError, ValueError):
        raise SystemExit("Invalid Rune update feed or Ed25519 key")
    options = {"SURequireSignedFeed": True, "SUVerifyUpdateBeforeExtraction": True,
               "SUAllowsAutomaticUpdates": False, "SUEnableAutomaticChecks": True, "SUSendProfileInfo": False}
    executable = framework / "Sparkle"
    if (not executable.is_file() or not os.access(executable, os.X_OK)
            or len(key) != 32 or key == base64.b64decode(upstream["SUPublicEDKey"])
            or any(info.get(k) is not v for k, v in options.items())):
        raise SystemExit("Invalid Rune update configuration or embedded framework")
elif framework.exists() or "SpottyRuneUpdateChannel" in info or any(k.startswith("SU") for k in info):
    raise SystemExit("Incomplete Rune update configuration")
PYTHON
codesign --verify --deep --strict --verbose=2 "$app_path"
signing_details="$(codesign --display --verbose=4 "$app_path" 2>&1)"
if ! grep -Eq 'flags=0x[0-9a-fA-F]+\([^)]*runtime' <<< "$signing_details"; then
    print -u2 "The app is signed without hardened runtime"
    exit 1
fi

if [[ "$require_distribution" == true ]]; then
    if [[ "$signing_details" != *"Authority=Developer ID Application:"* ]]; then
        print -u2 "Distribution validation requires a Developer ID Application signature"
        exit 1
    fi
    xcrun stapler validate "$app_path"
    spctl --assess --type execute --verbose=2 "$app_path"
fi

if [[ "$require_development_signature" == true ]]; then
    team_identifier="$(print -r -- "$signing_details" | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
    if [[ -z "$team_identifier" || "$team_identifier" == "not set" ]]; then
        print -u2 "Development validation requires an Apple-issued signature with a Team ID"
        exit 1
    fi
    if ! codesign --verify --strict -R '=anchor apple generic' "$app_path"; then
        print -u2 "Development validation requires an Apple-issued signing identity"
        exit 1
    fi
fi

print "Validated $app_path ($validation_mode)"
