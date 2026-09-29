#!/bin/zsh
set -euo pipefail

# Compile-only access-control contract for the testable SpottyCore module. The fixtures are never
# linked or run: the compiler must accept projection reads and reject reducer snapshot access
# and attempted writes. Independent desktop probes also reject concrete credential, gateway, and
# engine types accidentally re-exported by the runtime. Keep these compiler contracts instead
# of making a source spelling snapshot of PlaybackStore's implementation.
project_root="${0:A:h:h}"
fixtures_root="$project_root/Tests/Compiler/PlaybackStoreAccess"
positive_fixture="$fixtures_root/positive.swift"
negative_fixture="$fixtures_root/negative.swift"
desktop_negative_fixture="$project_root/Tests/Compiler/DesktopBoundary/negative.swift"
desktop_capability_fixture="$project_root/Tests/Compiler/DesktopBoundary/capabilities.swift"
engine_capability_fixture="$project_root/Tests/Compiler/EngineBoundary/capabilities.swift"

if (( $# > 1 )); then
    print -u2 "usage: $0 [SWIFT_BUILD_BIN_PATH]"
    exit 2
fi
if [[ ! -f "$positive_fixture" || ! -f "$negative_fixture" || ! -f "$desktop_negative_fixture" \
    || ! -f "$desktop_capability_fixture" || ! -f "$engine_capability_fixture" ]]; then
    print -u2 "Compiler access fixtures are missing"
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
    swift_bin_path="$(SPOTTY_PACKAGE_GRAPH=full swift build \
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

# Match the compiled module's package access; SwiftPM normalizes checkout identities differently
# from the declared Package name. Missing or inconsistent build metadata must fail closed.
package_identity="$(python3 "$project_root/Scripts/swift_package_identity.py" "$swift_bin_path")"

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

sparkle_slice="$project_root/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
if [[ ! -d "$sparkle_slice/Sparkle.framework" ]]; then
    print -u2 "Missing Sparkle framework under $sparkle_slice; run swift package resolve and rebuild the boundary tests"
    exit 1
fi

module_cache="$(mktemp -d /tmp/spotty-playback-projection-access.XXXXXX)"
trap 'rm -rf "$module_cache"' EXIT

minimum_macos="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$project_root/Packaging/Info.plist")"
swift_arguments=(
    -typecheck
    -parse-as-library
    -swift-version 6
    -warnings-as-errors
    -target "arm64-apple-macos$minimum_macos"
    -sdk "$sdk_path"
    -module-cache-path "$module_cache"
    "${swift_module_paths[@]}"
    -I "$c_module_path"
    -F "$sparkle_slice"
)

"$swiftc_path" "${swift_arguments[@]}" "$positive_fixture"

# Swift's diagnostic verifier checks every annotated location independently: accepting any one
# forbidden access leaves an unmet expectation, while missing modules and unrelated fixture errors
# also fail. Ignore diagnostics in imported modules, whose note locations are toolchain-specific;
# the positive fixture above independently requires those imports to type-check.
# This avoids launching one compiler per forbidden member without weakening the per-access proof.
for fixture in "$negative_fixture" "$desktop_negative_fixture" "$desktop_capability_fixture" "$engine_capability_fixture"; do
    if ! rg -q 'expected-error' "$fixture"; then
        print -u2 "Compiler fixture contains no expected failures: $fixture"
        exit 1
    fi
done
verify_arguments=(-Xfrontend -verify -Xfrontend -verify-ignore-unrelated)
"$swiftc_path" "${swift_arguments[@]}" "${verify_arguments[@]}" "$negative_fixture"
package_arguments=("${swift_arguments[@]}" -package-name "$package_identity")
"$swiftc_path" "${package_arguments[@]}" "${verify_arguments[@]}" "$desktop_negative_fixture"
"$swiftc_path" "${package_arguments[@]}" "${verify_arguments[@]}" "$desktop_capability_fixture"
"$swiftc_path" "${package_arguments[@]}" "${verify_arguments[@]}" "$engine_capability_fixture"
print "Compiler contracts passed: projection reads, forbidden writes, hidden implementations, and supported capabilities"
