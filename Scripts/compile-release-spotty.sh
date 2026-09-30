#!/bin/zsh
set -euo pipefail

# Compile-only release path for the shipping Spotty executable. Resolve and validate the pinned
# playback XCFramework (or explicit local override) before compilation. Its content-addressed
# library filename forces relinking even when a local artifact directory is reused.
# Does not run the Rust suite, Swift checks, packaging, or signing.
project_root="${0:A:h:h}"
source "$project_root/Scripts/ci-timings.sh"
trap 'spotty_ci_timings_finish "$?"' EXIT
if [[ -n "${SPOTTY_CI_TIMINGS_REPORT:-}" ]]; then
    trap 'spotty_ci_timings_finish "$?"' ZERR
fi
spotty_ci_timings_start release.environment
source "$project_root/Scripts/swiftpm-env.sh"
source "$project_root/Scripts/playback-xcframework.sh"
spotty_ci_timings_finish 0

spotty_ci_timings_start release.artifact.resolve
selected_xcframework="$(spotty_playback_resolve_xcframework)"
spotty_ci_timings_finish 0
spotty_ci_timings_start release.artifact.validate
spotty_playback_validate_xcframework "$selected_xcframework"
spotty_ci_timings_finish 0
spotty_ci_timings_start release.header-module-cache
playback_headers="$(spotty_playback_headers_path "$(spotty_playback_slice_path "$selected_xcframework")")"
python3 "$project_root/Scripts/playback_module_cache.py" "$project_root/.build" "$playback_headers" \
    --configuration release
spotty_ci_timings_finish 0

swift_arguments=(
    --disable-sandbox
    --package-path "$project_root"
    --configuration release
    --product Spotty
    -Xswiftc -DSPOTTY_DISTRIBUTION
    "${spotty_swiftc_warnings_as_errors[@]}"
)

spotty_ci_timings_start release.distribution-build
swift build "${swift_arguments[@]}"
spotty_ci_timings_finish 0

spotty_ci_timings_start release.bin-path-and-verification
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
spotty_ci_timings_finish 0

print "Compiled release Spotty with SPOTTY_DISTRIBUTION at $built_binary"
