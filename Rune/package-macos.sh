#!/bin/zsh
set -euo pipefail

if [[ "$(uname -s)-$(uname -m)" != Darwin-arm64 ]]; then
    print -u2 "The macOS Spotty bundle requires an Apple Silicon Mac."
    exit 1
fi

case "${1:---release}" in
    --debug|debug) profile=debug; cargo_profile=() ;;
    --release|release) profile=release; cargo_profile=(--release) ;;
    *) print -u2 "Usage: $0 [--debug|--release]"; exit 2 ;;
esac
if [[ -n "${SPOTTY_SIGNING_IDENTITY:-}" && -n "${SPOTTY_DEVELOPMENT_SIGNING_IDENTITY:-}" ]]; then
    print -u2 "Choose one signing identity."
    exit 2
fi
project_root=${0:A:h:h}
frontend="$project_root/Rune"
out="$project_root/.build/rune-app"
destination="${SPOTTY_APP_PATH:-$out/Spotty.app}"
destination=${destination:a}
[[ "${destination:t}" == Spotty.app ]] || { print -u2 "Destination must be a Spotty.app bundle"; exit 2; }
mkdir -p "$out"

cd "$frontend"
export MACOSX_DEPLOYMENT_TARGET=27.0
cargo build --manifest-path "$frontend/Cargo.toml" --locked "${cargo_profile[@]}" --target aarch64-apple-darwin \
    --target-dir "$out/rust"

mkdir -p "${destination:h}"
staging=$(mktemp -d "${destination:h}/.spotty-package.XXXXXX")
app="$staging/Spotty.app"

function cleanup {
    if [[ ! -e "$destination" && -d "$staging/Previous.app" ]]; then
        mv "$staging/Previous.app" "$destination"
    fi
    rm -rf -- "$staging"
}
trap cleanup EXIT

mkdir -p "$app/Contents/"{MacOS,Resources}
print -rn 'APPL????' > "$app/Contents/PkgInfo"
xcrun actool --compile "$app/Contents/Resources" --platform macosx --minimum-deployment-target "$MACOSX_DEPLOYMENT_TARGET" \
    --app-icon Spotty --output-partial-info-plist "$staging/icon.plist" "$project_root/Assets/Spotty.icon"
cp "$frontend/Info.plist" "$app/Contents/"
cp "$project_root/Assets/Spotty.icns" "$app/Contents/Resources/"
cp "$out/rust/aarch64-apple-darwin/$profile/spotty-rune" "$app/Contents/MacOS/Spotty"
cp "$project_root/LICENSE" "$project_root/NOTICE" "$app/Contents/Resources/"
python3 "$project_root/Scripts/generate-rune-notices.py" --output "$app/Contents/Resources"
identity="${SPOTTY_SIGNING_IDENTITY:-${SPOTTY_DEVELOPMENT_SIGNING_IDENTITY:--}}"
sign_args=(--force --options runtime --sign "$identity")
python3 "$frontend/configure-updates.py" "$app/Contents/Info.plist" "$project_root/Packaging/Info.plist"
if [[ -n "${SPOTTY_RUNE_UPDATE_FEED_URL:-}" ]]; then
    # Sparkle's standalone native framework distribution. The digest pins every nested helper.
    release="https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz"
    archive="$staging/Sparkle-2.10.0.tar.xz"
    curl --fail --location --silent --show-error "$release" --output "$archive"
    digest="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
    print -r -- "$digest  $archive" | shasum -a 256 -c -
    tar -xJf "$archive" -C "$staging" ./Sparkle.framework ./LICENSE
    cp "$staging/LICENSE" "$app/Contents/Resources/Sparkle-LICENSE"
    source "$project_root/Scripts/embed-sparkle.sh"
    spotty_embed_sparkle "$app" "$identity" --framework "$staging/Sparkle.framework"
    if [[ "$identity" == "-" ]]; then
        sign_args+=(--entitlements "$project_root/Packaging/AdHoc.entitlements")
    fi
fi
codesign "${sign_args[@]}" "$app"
"$project_root/Scripts/validate-app.sh" --local "$app"

if [[ -d "$destination" ]]; then mv "$destination" "$staging/Previous.app"; fi
mv "$app" "$destination"
print "$destination"
