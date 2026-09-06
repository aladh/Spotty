#!/bin/zsh
set -euo pipefail

if [[ "${1:-}" == "--demo" ]]; then
    exec "${0:A:h:h}/Scripts/browse-synthetic.sh" --interactive "${@:2}"
fi

mode="${1:-run}"
app_name="Spotty"
previous_app_name="$(printf '\101\165\162\141\154')"
bundle_id="dev.spotty.app"
root_dir="${0:A:h:h}"
app_bundle="$root_dir/Spotty.app"
previous_app_bundle="$root_dir/$previous_app_name.app"
app_binary="$app_bundle/Contents/MacOS/Spotty"
staged_app_bundle="$root_dir/.build/spotty-launch/Spotty.app"
rollback_app_bundle="$root_dir/.build/spotty-launch/Spotty.previous.app"

case "$mode" in
    --release|release|--verify-release|verify-release)
        package_mode="--release"
        ;;
    *)
        package_mode="--debug"
        ;;
esac

case "$mode" in
    run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify|--release|release|--verify-release|verify-release) ;;
    *)
        print -u2 "usage: $0 [run|--demo|--debug|--logs|--telemetry|--verify|--release|--verify-release]"
        exit 2
        ;;
esac

if [[ -z "${SPOTTY_SIGNING_IDENTITY:-}" && -z "${SPOTTY_DEVELOPMENT_SIGNING_IDENTITY:-}" ]]; then
    apple_development_identities="$(
        security find-identity -p codesigning -v 2>/dev/null \
            | sed -nE 's/^[[:space:]]*[0-9]+\) [[:xdigit:]]+ "(Apple Development:[^"]+)"$/\1/p'
    )"
    identity_count="$(print -r -- "$apple_development_identities" | sed '/^$/d' | wc -l | tr -d ' ')"
    if [[ "$identity_count" == "1" ]]; then
        export SPOTTY_DEVELOPMENT_SIGNING_IDENTITY="$(print -r -- "$apple_development_identities" | head -n 1)"
    elif [[ "$identity_count" == "0" ]]; then
        print -u2 "Authenticated Spotty development requires an Apple Development signing identity."
        print -u2 "Create one in Xcode Accounts, or package without launching via ./Scripts/package-app.sh."
        exit 1
    else
        print -u2 "Multiple Apple Development identities are available."
        print -u2 "Set SPOTTY_DEVELOPMENT_SIGNING_IDENTITY to the exact identity to use."
        exit 1
    fi
fi

SPOTTY_APP_PATH="$staged_app_bundle" "$root_dir/Scripts/package-app.sh" "$package_mode"
"$root_dir/Scripts/validate-app.sh" --keychain-stable "$staged_app_bundle"
pkill -x "$app_name" >/dev/null 2>&1 || true
pkill -x "$previous_app_name" >/dev/null 2>&1 || true
for _ in {1..20}; do
    if ! pgrep -x "$app_name" >/dev/null && ! pgrep -x "$previous_app_name" >/dev/null; then
        break
    fi
    sleep 0.1
done
if pgrep -x "$app_name" >/dev/null || pgrep -x "$previous_app_name" >/dev/null; then
    print -u2 "A development app did not terminate; leaving existing bundles in place"
    exit 1
fi
had_existing_bundle=false
if [[ -e "$app_bundle" ]]; then
    rm -rf "$rollback_app_bundle"
    mv "$app_bundle" "$rollback_app_bundle"
    had_existing_bundle=true
fi
if ! mv "$staged_app_bundle" "$app_bundle"; then
    if [[ "$had_existing_bundle" == true ]]; then
        if ! mv "$rollback_app_bundle" "$app_bundle"; then
            print -u2 "Failed to install the staged app and restore the previous bundle"
            exit 1
        fi
        print -u2 "Failed to install the staged app; restored the previous bundle"
    else
        print -u2 "Failed to install the staged app; no previous bundle was present"
    fi
    exit 1
fi
rm -rf "$rollback_app_bundle"
rm -rf "$previous_app_bundle"
rmdir "$root_dir/.build/spotty-launch" 2>/dev/null || true

open_app() {
    /usr/bin/open -n "$app_bundle"
}

case "$mode" in
    run)
        open_app
        ;;
    --debug|debug)
        lldb -- "$app_binary"
        ;;
    --logs|logs)
        open_app
        /usr/bin/log stream --info --style compact --predicate "process == \"$app_name\""
        ;;
    --telemetry|telemetry)
        open_app
        /usr/bin/log stream --info --style compact --predicate "subsystem == \"$bundle_id\""
        ;;
    --verify|verify)
        open_app
        for _ in {1..20}; do
            pgrep -x "$app_name" >/dev/null && exit 0
            sleep 0.1
        done
        print -u2 "Spotty did not launch"
        exit 1
        ;;
    --release|release)
        open_app
        ;;
    --verify-release|verify-release)
        open_app
        for _ in {1..20}; do
            pgrep -x "$app_name" >/dev/null && exit 0
            sleep 0.1
        done
        print -u2 "Spotty release build did not launch"
        exit 1
        ;;
    *)
        print -u2 "usage: $0 [run|--demo|--debug|--logs|--telemetry|--verify|--release|--verify-release]"
        exit 2
        ;;
esac
