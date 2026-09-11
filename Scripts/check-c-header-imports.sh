#!/bin/zsh
set -euo pipefail

# Compile-only Swift importer contract. This deliberately type-checks an uncalled fixture and
# never links or runs the playback library.
project_root="$(cd "$(dirname "$0")/.." && pwd)"
if (( $# > 1 )); then
    print -u2 "usage: $0 [XCFRAMEWORK_HEADERS]"
    exit 2
fi
header_dir="${1:-${SPOTTY_PLAYBACK_HEADER_DIR:-$project_root/Sources/SpottyPlaybackCore/include}}"
header_path="$header_dir/spotty_playback.h"
positive_fixture="$project_root/Tests/ABI/positive.swift"
negative_fixture="$project_root/Tests/ABI/negative.swift"

if [[ ! -f "$header_path" || ! -f "$positive_fixture" || ! -f "$negative_fixture" ]]; then
    print -u2 "Swift C-header import fixtures are missing"
    exit 1
fi
if ! command -v xcrun >/dev/null 2>&1; then
    print -u2 "xcrun is required to type-check the Swift C-header import fixture"
    exit 1
fi

swiftc_path="$(xcrun --find swiftc 2>/dev/null || true)"
if [[ -z "$swiftc_path" || ! -x "$swiftc_path" ]]; then
    print -u2 "swiftc was not found in the selected Xcode/Swift toolchain"
    exit 1
fi
sdk_path="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
if [[ -z "$sdk_path" || ! -d "$sdk_path" ]]; then
    print -u2 "macOS SDK was not found in the selected Xcode/Swift toolchain"
    exit 1
fi

module_cache="$(mktemp -d /tmp/spotty-c-header-imports.XXXXXX)"
trap 'rm -rf "$module_cache"' EXIT

swift_arguments=(
    -typecheck
    -swift-version 6
    -warnings-as-errors
    -import-objc-header "$header_path"
    -I "$header_dir"
    -target arm64-apple-macos15.0
    -sdk "$sdk_path"
    -module-cache-path "$module_cache"
)

"$swiftc_path" "${swift_arguments[@]}" "$positive_fixture"

negative_flags=("${(@f)$(sed -nE 's/^#if (NEG_[A-Z0-9_]+).*$/\1/p' "$negative_fixture" | sort -u)}")
(( ${#negative_flags} > 0 )) || { print -u2 "No negative ABI probes found"; exit 1; }
for negative_flag in "${negative_flags[@]}"; do
    negative_log="$module_cache/$negative_flag.err"
    if "$swiftc_path" "${swift_arguments[@]}" "-D$negative_flag" "$negative_fixture" > /dev/null 2> "$negative_log"; then
        print -u2 "negative $negative_flag probe unexpectedly compiled"
        exit 1
    fi
    if ! rg -q "optional type|must be unwrapped" "$negative_log"; then
        print -u2 "negative $negative_flag probe failed for an unexpected reason"
        cat "$negative_log" >&2
        exit 1
    fi
done

print "Swift C-header import contract passed: positive import and ${#negative_flags} nullability negatives"
