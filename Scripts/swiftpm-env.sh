# Shared SDKROOT and repo-local Swift module cache. Sourced by check.sh and
# compile-release-spotty.sh. Not a check runner and not an entry point.
if [[ -z "${project_root:-}" ]]; then
    print -u2 "project_root must be set before sourcing Scripts/swiftpm-env.sh"
    return 1 2>/dev/null || exit 1
fi

sdk_path="$(env -u SDKROOT xcrun --sdk macosx --show-sdk-path)"
if [[ -z "$sdk_path" ]]; then
    print -u2 "xcrun returned no macOS SDK path"
    return 1 2>/dev/null || exit 1
fi

mkdir -p "$project_root/.build/module-cache"
export SDKROOT="$sdk_path"
export CLANG_MODULE_CACHE_PATH="$project_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$project_root/.build/module-cache"

# Every app/gate entry point starts with the complete package graph. Isolated tests
# opt in only on their own Swift invocation, never through an inherited shell setting.
export SPOTTY_PACKAGE_GRAPH=full

# Spotty-owned `swift build` invocations treat compiler warnings as errors.
# Command-line -Xswiftc only; do not put this in Package.swift unsafeFlags.
spotty_swiftc_warnings_as_errors=(-Xswiftc -warnings-as-errors)
