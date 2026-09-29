#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"

SPOTTY_PACKAGE_GRAPH=full swift package --package-path "$project_root" clean
playback_input_digest="$("$project_root/Backend/spotty-playback/source-input-digest.sh")"
local_xcframework="$project_root/.build/playback-engine/$playback_input_digest/SpottyPlaybackCore.xcframework"
"$project_root/Backend/spotty-playback/build-xcframework.sh"
SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK="$local_xcframework" \
    "$project_root/Scripts/check.sh"
SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK="$local_xcframework" \
    SPOTTY_BUILD_CONFIGURATION=release "$project_root/Scripts/check.sh"

print "Spotty clean Debug and Release quality gates passed"
