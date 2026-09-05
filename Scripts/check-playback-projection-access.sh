#!/bin/zsh
set -euo pipefail

# Compile-only access-control contract for the testable SpottyCore module. The fixtures are never
# linked or run: the compiler must accept reads of the store snapshot/projections and reject each
# attempted write. Keep this next to the C-header compiler contract rather than making a source
# spelling snapshot of PlaybackStore's implementation.
project_root="${0:A:h:h}"
fixtures_root="$project_root/Tests/Compiler/PlaybackStoreAccess"
positive_fixture="$fixtures_root/positive.swift"
negative_fixture="$fixtures_root/negative.swift"

if (( $# > 1 )); then
    print -u2 "usage: $0 [SWIFT_BUILD_BIN_PATH]"
    exit 2
fi
if [[ ! -f "$positive_fixture" || ! -f "$negative_fixture" ]]; then
    print -u2 "PlaybackStore compiler access fixtures are missing"
    exit 1
fi
if ! command -v swift >/dev/null 2>&1; then
    print -u2 "swift is required to locate the built SpottyCore module"
    exit 1
fi
if ! command -v xcrun >/dev/null 2>&1; then
    print -u2 "xcrun is required to type-check the PlaybackStore compiler fixtures"
    exit 1
fi

swiftc_path="$(xcrun --find swiftc 2>/dev/null || true)"
if [[ -z "$swiftc_path" || ! -x "$swiftc_path" ]]; then
    print -u2 "swiftc was not found in the selected Xcode/Swift toolchain"
    exit 1
fi
sdk_path="${SDKROOT:-}"
if [[ -z "$sdk_path" || ! -d "$sdk_path" ]]; then
    sdk_path="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
fi
if [[ -z "$sdk_path" || ! -d "$sdk_path" ]]; then
    print -u2 "macOS SDK was not found in the selected Xcode/Swift toolchain"
    exit 1
fi

swift_bin_path="${1:-${SPOTTY_SWIFT_BUILD_BIN_PATH:-}}"
if [[ -z "$swift_bin_path" ]]; then
    swift_bin_path="$(swift build \
        --disable-sandbox \
        --package-path "$project_root" \
        --configuration debug \
        --show-bin-path 2>/dev/null)"
fi
if [[ ! -d "$swift_bin_path" ]]; then
    print -u2 "SwiftPM Debug build output directory is missing: ${swift_bin_path:-<none>}"
    print -u2 "Run the boundary test target before checking PlaybackStore access"
    exit 1
fi

# Xcode's SwiftPM build system selects the active Xcode SDK for its Products modules,
# even when the shell SDKROOT points at a compatible command-line SDK. Match that build.
if [[ -d "$swift_bin_path/SpottyCore.swiftmodule" ]]; then
    sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
fi

# SwiftPM's output layout differs between the command-line and Xcode build systems. The Debug
# boundary test always builds a testable SpottyCore module; include both known Swift module
# locations, then select exactly one C module-map location. Passing the generated and checked-in
# module maps together produces a Clang redefinition diagnostic.
swift_module_paths=()
for candidate in "$swift_bin_path" "$swift_bin_path/Modules"; do
    if [[ -d "$candidate" ]]; then
        swift_module_paths+=(-I "$candidate")
    fi
done
if (( ${#swift_module_paths[@]} == 0 )); then
    print -u2 "No Swift module search paths were found under: $swift_bin_path"
    exit 1
fi
c_module_path=""
for candidate in "$swift_bin_path/include" "$swift_bin_path/SpottyPlaybackCore.build"; do
    if [[ -f "$candidate/module.modulemap" ]]; then
        c_module_path="$candidate"
        break
    fi
done
if [[ -z "$c_module_path" ]]; then
    source "$project_root/Scripts/playback-xcframework.sh"
    selected_xcframework="$(spotty_playback_resolve_xcframework)"
    c_module_path="$(spotty_playback_headers_path "$(spotty_playback_slice_path "$selected_xcframework")")"
fi
if [[ -z "$c_module_path" ]]; then
    print -u2 "SpottyPlaybackCore's module map is missing from SwiftPM output: $swift_bin_path"
    exit 1
fi

module_cache="$(mktemp -d /tmp/spotty-playback-projection-access.XXXXXX)"
trap 'rm -rf "$module_cache"' EXIT

swift_arguments=(
    -typecheck
    -parse-as-library
    -swift-version 6
    -warnings-as-errors
    -target arm64-apple-macos15.0
    -sdk "$sdk_path"
    -module-cache-path "$module_cache"
    "${swift_module_paths[@]}"
    -I "$c_module_path"
)

"$swiftc_path" "${swift_arguments[@]}" "$positive_fixture"

# Keep one probe per access surface. A single fixture containing all writes could still fail if a
# new writable projection were added next to an existing invalid write; independent diagnostics
# make each access-control promise observable. The compiler's diagnostic wording is intentionally
# the only assertion here: no production source or generated interface is parsed by the script.
# The conditional fixture is the inventory: adding a negative branch automatically runs it.
negative_flags=("${(@f)$(awk '/^[[:space:]]*#(if|elseif) NEG_[A-Z_]+$/ { print $2 }' "$negative_fixture")}")
if (( ${#negative_flags} == 0 )) || [[ -z "${negative_flags[1]}" ]]; then
    print -u2 "PlaybackStore compiler fixture contains no negative probes"
    exit 1
fi

for flag in "${negative_flags[@]}"; do
    negative_log="$module_cache/$flag.err"
    if "$swiftc_path" "${swift_arguments[@]}" "-D$flag" "$negative_fixture" \
        > /dev/null 2> "$negative_log"; then
        print -u2 "negative $flag probe unexpectedly compiled"
        exit 1
    fi
    if ! rg -q 'setter is inaccessible|get-only property' "$negative_log"; then
        print -u2 "negative $flag probe failed for an unexpected reason"
        cat "$negative_log" >&2
        exit 1
    fi
done

print "PlaybackStore compiler access contract passed: positive reads and ${#negative_flags} access-control negatives"
