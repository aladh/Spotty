#!/bin/zsh
set -euo pipefail

package_mode="${1:---debug}"
case "$package_mode" in
    --debug|debug) build_configuration="debug" ;;
    --release|release) build_configuration="release" ;;
    *)
        print -u2 "usage: $0 [--debug|--release]"
        exit 2
        ;;
esac

project_root="${0:A:h:h}"
source "$project_root/Scripts/playback-xcframework.sh"
source "$project_root/Scripts/embed-sparkle.sh"
app_path="${SPOTTY_APP_PATH:-$project_root/Spotty.app}"
staged_launch_path="$project_root/.build/spotty-launch/Spotty.app"
executable="$project_root/.build/$build_configuration/Spotty"
icon_source="$project_root/Assets/Spotty.icon"
legacy_icon="$project_root/Assets/Spotty.icns"
icon_build_dir="$project_root/.build/spotty-icon/$build_configuration"
compiled_assets="$icon_build_dir/Assets.car"
info_template="$project_root/Packaging/Info.plist"
third_party_notices="$project_root/THIRD_PARTY_NOTICES.md"
# Version bump procedure: edit CFBundleShortVersionString and CFBundleVersion in
# Packaging/Info.plist (the source of truth); SPOTTY_VERSION/SPOTTY_BUILD_NUMBER are
# one-off overrides only and must not be relied on for releases.
app_version="${SPOTTY_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_template")}"
app_build_number="${SPOTTY_BUILD_NUMBER:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_template")}"
distribution_identity="${SPOTTY_SIGNING_IDENTITY:-}"
development_identity="${SPOTTY_DEVELOPMENT_SIGNING_IDENTITY:-}"

if [[ -n "$distribution_identity" && -n "$development_identity" ]]; then
    print -u2 "Set only one of SPOTTY_SIGNING_IDENTITY or SPOTTY_DEVELOPMENT_SIGNING_IDENTITY"
    exit 2
fi

export SPOTTY_BUILD_CONFIGURATION="$build_configuration"
export SPOTTY_CHECK_SCOPE=swift

if ! command -v xcrun >/dev/null 2>&1; then
    print -u2 "Native Spotty icon packaging requires xcrun from a full Xcode installation"
    print -u2 "Select Xcode with xcode-select or set DEVELOPER_DIR, then retry packaging"
    exit 1
fi
actool="$(xcrun --find actool 2>/dev/null || true)"
if [[ -z "$actool" || ! -x "$actool" ]]; then
    print -u2 "Native Spotty icon packaging requires Apple's actool (Icon Composer compiler)"
    print -u2 "Select Xcode 26.2 or newer with xcode-select -s, or set DEVELOPER_DIR, then retry packaging"
    exit 1
fi

if [[ ! -d "$icon_source" ]]; then
    print -u2 "Missing native Spotty icon source: $icon_source"
    exit 1
fi
rm -rf "$icon_build_dir"
mkdir -p "$icon_build_dir"
# actool needs the partial-info output to emit this icon catalog; bundle metadata stays in the template.
actool_output=""
if ! actool_output="$("$actool" \
    --compile "$icon_build_dir" \
    --platform macosx \
    --minimum-deployment-target 15.0 \
    --app-icon Spotty \
    --output-partial-info-plist "$icon_build_dir/asset-info.plist" \
    "$icon_source" 2>&1)"; then
    print -u2 "Failed to compile native Spotty icon with actool: $icon_source"
    if [[ -n "$actool_output" ]]; then
        print -u2 -- "$actool_output"
    fi
    exit 1
fi
if [[ ! -s "$compiled_assets" ]]; then
    print -u2 "actool did not produce the native Spotty icon catalog: $compiled_assets"
    exit 1
fi
"$project_root/Scripts/check.sh"

selected_xcframework="$(spotty_playback_resolve_xcframework)"
playback_slice="$(spotty_playback_slice_path "$selected_xcframework")"
playback_notices="$selected_xcframework/Notices"
if [[ ! -d "$playback_notices" || ! -f "$playback_notices/ThirdPartyNotices.md" || ! -f "$playback_notices/manifest.json" || ! -d "$playback_notices/licenses" || ! -f "$selected_xcframework/spotty_playback_provenance.json" ]]; then
    print -u2 "Selected playback XCFramework is missing its notices or provenance material"
    exit 1
fi

playback_archive="$(spotty_playback_archive_path "$playback_slice")"
for required_file in "$executable" "$legacy_icon" "$info_template" "$third_party_notices" "$playback_archive"; do
    if [[ ! -f "$required_file" ]]; then
        print -u2 "Missing packaging input: $required_file"
        exit 1
    fi
done

if [[ ! "$app_version" =~ '^[0-9]+(\.[0-9]+){1,2}$' ]]; then
    print -u2 "SPOTTY_VERSION must be a numeric dotted version"
    exit 2
fi
if [[ ! "$app_build_number" =~ '^[1-9][0-9]*$' ]]; then
    print -u2 "SPOTTY_BUILD_NUMBER must be a positive integer"
    exit 2
fi

# This is a generated bundle at one exact path; recreate it so stale binaries and resources
# cannot survive a packaging run.
if [[ "$app_path" != "$project_root/Spotty.app" && "$app_path" != "$staged_launch_path" ]]; then
    print -u2 "Refusing to replace an unexpected app path"
    exit 1
fi
rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
printf 'APPL????' > "$app_path/Contents/PkgInfo"
cp "$executable" "$app_path/Contents/MacOS/Spotty"
cp "$compiled_assets" "$app_path/Contents/Resources/Assets.car"
cp "$legacy_icon" "$app_path/Contents/Resources/Spotty.icns"
cp "$third_party_notices" "$app_path/Contents/Resources/ThirdPartyNotices.md"
mkdir -p "$app_path/Contents/Resources/PlaybackNotices"
cp -R "$playback_notices/." "$app_path/Contents/Resources/PlaybackNotices/"
cp "$selected_xcframework/spotty_playback_provenance.json" \
    "$app_path/Contents/Resources/PlaybackNotices/spotty_playback_provenance.json"
cp "$info_template" "$app_path/Contents/Info.plist"

# Debug builds have a checkout-scoped non-secret identity, separate from installed Release defaults.
# Persist outside the replaced bundle so rebuilds and launches retain it, including in worktrees.
if [[ "$build_configuration" == debug ]]; then
    development_id_file="$project_root/.spotty-connect-device-id"
    if [[ ! -f "$development_id_file" ]]; then
        python3 - "$development_id_file" "$project_root/.build/connect-device-id" <<'PYID'
import os
from pathlib import Path
import re
import secrets
import sys
import tempfile

target, previous = map(Path, sys.argv[1:])
if previous.exists() or previous.is_symlink():
    if previous.is_symlink() or not previous.is_file():
        raise SystemExit(f"Invalid development Connect identity at {previous}")
    identity = previous.read_text().strip()
else:
    identity = secrets.token_hex(20)
if not re.fullmatch(r"[0-9a-f]{40}", identity):
    raise SystemExit(f"Invalid development Connect identity at {previous}")
with tempfile.NamedTemporaryFile(mode="w", dir=target.parent) as staged:
    staged.write(identity + "\n")
    staged.flush()
    try:
        os.link(staged.name, target)
    except FileExistsError:
        pass  # Another package invocation already published its complete identity.
PYID
    fi
    development_id="$(cat "$development_id_file")"
    if [[ ! "$development_id" =~ '^[0-9a-f]{40}$' ]]; then
        print -u2 "Invalid development Connect identity at $development_id_file"
        exit 1
    fi
    plutil -insert SpottyConnectDeviceID -string "$development_id" "$app_path/Contents/Info.plist"
fi

plutil -replace CFBundleShortVersionString -string "$app_version" "$app_path/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$app_build_number" "$app_path/Contents/Info.plist"
plutil -lint "$app_path/Contents/Info.plist"

sign_with_local_identity() {
    local signing_dir="$project_root/.build/spotty-signing"
    local signing_keychain="$signing_dir/Spotty.keychain-db"
    local password_file="$signing_dir/keychain-password"
    local identity_name="Spotty Local Development"

    mkdir -p "$signing_dir"
    chmod 700 "$signing_dir"

    if [[ ! -f "$password_file" ]]; then
        openssl rand -hex -out "$password_file" 32
        chmod 600 "$password_file"
    fi
    local signing_password="$(tr -d '\n' < "$password_file")"

    if [[ ! -f "$signing_dir/certificate.pem" || ! -f "$signing_dir/private-key.pem" ]]; then
        openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
            -subj '/CN=Spotty Local Development/O=Spotty' \
            -addext 'keyUsage=critical,digitalSignature' \
            -addext 'extendedKeyUsage=codeSigning' \
            -keyout "$signing_dir/private-key.pem" \
            -out "$signing_dir/certificate.pem"
        chmod 600 "$signing_dir/private-key.pem"
    fi

    if [[ ! -f "$signing_dir/identity.p12" ]]; then
        local pkcs12_help
        local pkcs12_compatibility=()
        pkcs12_help="$(openssl pkcs12 -help 2>&1 || true)"
        if [[ "$pkcs12_help" == *"-legacy"* ]]; then
            pkcs12_compatibility=(-legacy)
        fi
        openssl pkcs12 -export "${pkcs12_compatibility[@]}" \
            -out "$signing_dir/identity.p12" \
            -inkey "$signing_dir/private-key.pem" \
            -in "$signing_dir/certificate.pem" \
            -passout "pass:$signing_password"
        chmod 600 "$signing_dir/identity.p12"
    fi

    if [[ ! -f "$signing_keychain" ]]; then
        security create-keychain -p "$signing_password" "$signing_keychain"
        security set-keychain-settings -lut 21600 "$signing_keychain"
    fi
    security unlock-keychain -p "$signing_password" "$signing_keychain"

    if ! security find-certificate -c "$identity_name" "$signing_keychain" >/dev/null 2>&1; then
        security import "$signing_dir/identity.p12" \
            -k "$signing_keychain" \
            -P "$signing_password" \
            -T /usr/bin/codesign
        security set-key-partition-list \
            -S apple-tool:,apple:,codesign: \
            -s -k "$signing_password" \
            "$signing_keychain"
    fi

    spotty_embed_sparkle "$app_path" "$identity_name" --timestamp=none --keychain "$signing_keychain"
    codesign --force --options runtime --timestamp=none \
        --keychain "$signing_keychain" \
        --entitlements "$project_root/Packaging/AdHoc.entitlements" \
        --sign "$identity_name" \
        "$app_path"
}

if [[ "$distribution_identity" == "-" ]]; then
    spotty_embed_sparkle "$app_path" - --timestamp=none
    codesign --force --options runtime --timestamp=none \
        --sign - \
        --entitlements "$project_root/Packaging/AdHoc.entitlements" \
        "$app_path"
    signing_kind="ad hoc"
elif [[ -n "$distribution_identity" ]]; then
    spotty_embed_sparkle "$app_path" "$distribution_identity" --timestamp
    codesign --force --options runtime --timestamp \
        --sign "$distribution_identity" \
        "$app_path"
    signing_kind="Developer ID"
elif [[ -n "$development_identity" ]]; then
    spotty_embed_sparkle "$app_path" "$development_identity" --timestamp=none
    codesign --force --options runtime --timestamp=none \
        --sign "$development_identity" \
        "$app_path"
    signing_kind="Apple-team development"
else
    sign_with_local_identity
    signing_kind="local development"
fi

"$project_root/Scripts/validate-app.sh" --local "$app_path"
if [[ -n "$development_identity" ]]; then
    "$project_root/Scripts/validate-app.sh" --development-signed "$app_path"
fi

if [[ "$build_configuration" == "release" && -n "$development_identity" ]]; then
    print -u2 "Release bundle uses an Apple Development identity; set SPOTTY_SIGNING_IDENTITY to create a distributable Developer ID build."
elif [[ "$build_configuration" == "release" && -z "$distribution_identity" ]]; then
    print -u2 "Release bundle uses the local identity; set SPOTTY_SIGNING_IDENTITY to create a distributable Developer ID build."
elif [[ "$build_configuration" == "release" && "$distribution_identity" == "-" ]]; then
    print -u2 "Release bundle uses an ad-hoc signature; set SPOTTY_SIGNING_IDENTITY to a Developer ID identity for distribution."
fi
if [[ -z "$distribution_identity" && -z "$development_identity" ]]; then
    print -u2 "Self-signed bundles are build-only: authenticated launches require an Apple-issued team identity."
fi

print "Packaged $app_path ($build_configuration, $signing_kind signature, version $app_version ($app_build_number))"
