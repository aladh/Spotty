#!/bin/zsh
set -euo pipefail

# Compile-only release path for the shipping Spotty executable. SwiftPM resolves the pinned
# playback XCFramework (or the explicit local override) and owns its cache. The artifact path is
# content-addressed so a changed engine cannot be hidden behind a stale SwiftPM archive path.
# Does not run the Rust suite, Swift checks, packaging, or signing.
project_root="${0:A:h:h}"
source "$project_root/Scripts/swiftpm-env.sh"
source "$project_root/Scripts/playback-xcframework.sh"

selected_xcframework="$(spotty_playback_resolve_xcframework)"
spotty_playback_validate_xcframework "$selected_xcframework"

swift_arguments=(
    --disable-sandbox
    --package-path "$project_root"
    --configuration release
    --product Spotty
    -Xswiftc -DSPOTTY_DISTRIBUTION
    "${spotty_swiftc_warnings_as_errors[@]}"
)

swift build "${swift_arguments[@]}"

bin_path="$(swift build "${swift_arguments[@]}" --show-bin-path)"
case "$bin_path" in
    */release)
        debug_binary="${bin_path%/release}/debug/Spotty"
        ;;
    */Products/Release)
        debug_binary="${bin_path%/Release}/Debug/Spotty"
        ;;
    *)
        print -u2 "Release compile must use the release configuration, not $bin_path"
        exit 1
        ;;
esac

built_binary="$bin_path/Spotty"
if [[ ! -x "$built_binary" ]]; then
    print -u2 "Release compile did not produce an executable at $built_binary"
    exit 1
fi

if [[ -e "$debug_binary" ]]; then
    if [[ "$(realpath "$built_binary")" == "$(realpath "$debug_binary")" ]]; then
        print -u2 "Release compile reused the debug executable"
        exit 1
    fi
    if [[ "$(stat -f '%d:%i' "$built_binary")" == "$(stat -f '%d:%i' "$debug_binary")" ]]; then
        print -u2 "Release compile reused the debug executable"
        exit 1
    fi
fi

print "Compiled release Spotty with SPOTTY_DISTRIBUTION at $built_binary"
