#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
build_configuration="${SPOTTY_BUILD_CONFIGURATION:-debug}"
check_scope="${SPOTTY_CHECK_SCOPE:-full}"
source "$project_root/Scripts/swiftpm-env.sh"
source "$project_root/Scripts/playback-xcframework.sh"

case "$build_configuration" in
    debug|release) ;;
    *)
        print -u2 "SPOTTY_BUILD_CONFIGURATION must be debug or release"
        exit 2
        ;;
esac
case "$check_scope" in
    full|rust|swift) ;;
    *)
        print -u2 "SPOTTY_CHECK_SCOPE must be full, rust, or swift"
        exit 2
        ;;
esac

if [[ "$check_scope" == full ]]; then
    "$project_root/Scripts/check-source-policy.sh"
fi

# Fail fast on Swift format drift before Rust or Swift compilation.
# The sibling self-test covers wrapper discovery/failure contracts without a Swift toolchain.
if [[ "$check_scope" != rust ]]; then
    "$project_root/Scripts/format-swift-self-test.sh"
    "$project_root/Scripts/format-swift.sh" --check
fi

# The Rust suite owns lifecycle, generation, queue conversion, typed C snapshots,
# and compile-time C signature checks. Prefer the developer's normal toolchain;
# the fallback is the project-local toolchain provisioned by the development
# bootstrap on this workspace.
if [[ "$check_scope" != swift ]]; then
    python3 -B -m unittest discover -s "$project_root/Scripts" -p 'test_playback_*.py'
    cargo_bin="${SPOTTY_CARGO:-}"
    if [[ -z "$cargo_bin" ]]; then
        cargo_bin="$(command -v cargo || true)"
    fi
    workspace_cargo="/private/tmp/spotty-rustup/toolchains/stable-aarch64-apple-darwin/bin/cargo"
    if [[ -z "$cargo_bin" && -x "$workspace_cargo" ]]; then
        cargo_bin="$workspace_cargo"
        export CARGO_HOME="${CARGO_HOME:-/private/tmp/spotty-cargo}"
        export RUSTUP_HOME="${RUSTUP_HOME:-/private/tmp/spotty-rustup}"
        export PATH="${cargo_bin:h}:$PATH"
    fi
    if [[ -z "$cargo_bin" || ! -x "$cargo_bin" ]]; then
        print -u2 "Rust cargo was not found. Install Rust or set SPOTTY_CARGO to an executable cargo path."
        exit 1
    fi
    if [[ "$cargo_bin" == */* ]]; then
        export PATH="${cargo_bin:h}:$PATH"
    fi

    # Regeneration is a Rust-lane development-tool check. The app and Swift lane continue to
    # consume the checked-in header; cbindgen is never downloaded as part of an app build.
    "$project_root/Scripts/generate-c-header.sh" --check

    "$cargo_bin" fmt --all --manifest-path "$project_root/Backend/spotty-playback/Cargo.toml" -- --check
    "$cargo_bin" clippy --locked --manifest-path "$project_root/Backend/spotty-playback/Cargo.toml" \
        --all-targets -- -D warnings
    "$cargo_bin" test --locked --manifest-path "$project_root/Backend/spotty-playback/Cargo.toml"

    if [[ "$check_scope" == rust ]]; then
        print "Spotty Rust checks passed: formatting, warning-clean clippy, and locked tests are green"
        exit 0
    fi
fi

# Resolve one immutable playback artifact and keep all C/ABI checks paired with the headers
# shipped beside its selected archive. The SwiftPM resolver owns remote downloads; a source-built
# engine must be selected explicitly with SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK.
selected_xcframework="$(spotty_playback_resolve_xcframework)"
spotty_playback_validate_xcframework "$selected_xcframework"
playback_slice="$(spotty_playback_slice_path "$selected_xcframework")"
playback_archive="$(spotty_playback_archive_path "$playback_slice")"
playback_headers="$(spotty_playback_headers_path "$playback_slice")"
"$project_root/Scripts/check-c-header-imports.sh" "$playback_headers"
playback_header="$playback_headers/spotty_playback.h"

# Keep the selected artifact's C header and its static-library exports in exact
# agreement. Apple's nm can warn on newer Rust LLVM attributes in unrelated
# compiler-builtins objects, but it still emits the defined Spotty symbols; the
# exact set comparison below is the contract check.
header_symbols="$(mktemp /tmp/spotty-header-symbols.XXXXXX)"
header_symbol_declarations="$(mktemp /tmp/spotty-header-symbol-declarations.XXXXXX)"
library_symbols="$(mktemp /tmp/spotty-library-symbols.XXXXXX)"
consumed_symbols="$(mktemp /tmp/spotty-consumed-symbols.XXXXXX)"
header_ast="$(mktemp /tmp/spotty-header-ast.XXXXXX)"
trap 'rm -f "$header_symbols" "$header_symbol_declarations" "$library_symbols" "$consumed_symbols" "$header_ast"' EXIT

# Parse the artifact's umbrella header once. Clang follows its quoted includes, so declarations in the
# bundled cbindgen fragment remains part of the symbol and dead-export contracts.
if ! command -v clang >/dev/null 2>&1; then
    print -u2 "Clang is required to inspect the checked-in Spotty C ABI signatures"
    exit 1
fi
if ! clang -I "$playback_headers" -x c -fsyntax-only -Xclang -ast-dump \
    "$playback_header" > "$header_ast" 2>/dev/null; then
    print -u2 "Clang could not parse the Spotty C ABI header shipped in the selected XCFramework"
    exit 1
fi
sed -nE "s/.*FunctionDecl .* (spotty_playback_[a-z0-9_]+) '([^']+)'$/\\1/p" \
    "$header_ast" > "$header_symbol_declarations"
sort -u "$header_symbol_declarations" > "$header_symbols"
header_declaration_count="$(wc -l < "$header_symbol_declarations" | tr -d '[:space:]')"
header_symbol_count="$(wc -l < "$header_symbols" | tr -d '[:space:]')"
if (( header_declaration_count != header_symbol_count )); then
    print -u2 "The C ABI header declares a Spotty export more than once"
    exit 1
fi
(nm -gU "$playback_archive" 2>/dev/null || true) \
    | sed -nE 's/.*_(spotty_playback_[a-z0-9_]+)$/\1/p' \
    | sort -u > "$library_symbols"
if ! diff -u "$header_symbols" "$library_symbols"; then
    print -u2 "The XCFramework C header and selected SpottyPlaybackCore archive export different Spotty symbols"
    exit 1
fi

# Dead C exports cannot regrow silently: every remaining header symbol must be
# called from the sole SpottyPlaybackCore adapter. Reuses the header extractor's
# call-site token pattern rather than a second parser or generated binding.
# Line comments and quoted strings are dropped first so a mention is not a call.
playback_core="$project_root/Sources/Spotty/Spotify/PlaybackCore.swift"
sed -e 's://.*::' -e 's/"[^"]*"//g' "$playback_core" \
    | rg -o --pcre2 'spotty_playback_[a-z0-9_]+(?=\s*\()' \
    | sort -u > "$consumed_symbols"
unused_header_exports="$(comm -23 "$header_symbols" "$consumed_symbols")"
if [[ -n "$unused_header_exports" ]]; then
    print -u2 "Header exports not called from PlaybackCore.swift:"
    print -u2 "$unused_header_exports"
    exit 1
fi

swift_arguments=(
    --disable-sandbox
    --package-path "$project_root"
    --configuration "$build_configuration"
    --product Spotty
)
# SwiftPM owns relinking. Published artifacts and source-built local overrides use a
# content-addressed XCFramework/library path so changing the selected engine is a dependency
# identity change, rather than a replacement hidden behind the same archive path.
if [[ -n "${SPOTTY_SIGNING_IDENTITY:-}" ]]; then
    swift_arguments+=(-Xswiftc -DSPOTTY_DISTRIBUTION)
fi
swift_arguments+=("${spotty_swiftc_warnings_as_errors[@]}")

swift build "${swift_arguments[@]}"

# Pure domain and deterministic scenario tests stay separate from the shipping
# application target. SwiftPM discovers and runs them through Swift Testing.
domain_test_arguments=(
    --disable-sandbox
    --package-path "$project_root"
    --configuration "$build_configuration"
    --filter SpottyDomainTests
    "${spotty_swiftc_warnings_as_errors[@]}"
)
repeat_count="${SPOTTY_CHECK_REPEATS:-1}"
if ! [[ "$repeat_count" =~ '^[1-9][0-9]*$' ]] || (( repeat_count > 25 )); then
    print -u2 "SPOTTY_CHECK_REPEATS must be between 1 and 25"
    exit 2
fi
for (( run = 1; run <= repeat_count; run++ )); do
    swift test "${domain_test_arguments[@]}"
done

# Concrete codecs/parsers and injected coordinator/queue workflows compile against the real app
# core in a separate debug test target because it uses `@testable import SpottyCore`. The shipping
# Spotty and pure-domain tests above still honor a requested release configuration without enabling
# testability in production code.
boundary_test_arguments=(
    --disable-sandbox
    --no-parallel
    --package-path "$project_root"
    --configuration debug
    --filter SpottyBoundaryTests
    "${spotty_swiftc_warnings_as_errors[@]}"
)
for (( run = 1; run <= repeat_count; run++ )); do
    swift test "${boundary_test_arguments[@]}"
done

# Check mutation access against the actual testable Debug module built by the boundary suite.
"$project_root/Scripts/check-playback-projection-access.sh"

# Authenticated development must never silently fall back to a self-signed identity. On current
# macOS that gives the Keychain item a per-build CDHash partition and recreates the password prompt
# after every rebuild. Packaging may remain self-signed for deterministic build verification, but
# the launch entry point must require the Apple anchor + Team ID validator.
if ! rg -q --fixed-strings 'SPOTTY_DEVELOPMENT_SIGNING_IDENTITY' \
    "$project_root/script/build_and_run.sh" \
    || ! rg -q --fixed-strings 'validate-app.sh" --keychain-stable' \
        "$project_root/script/build_and_run.sh" \
    || ! rg -q --fixed-strings 'SPOTTY_APP_PATH="$staged_app_bundle"' \
        "$project_root/script/build_and_run.sh" \
    || ! rg -q --fixed-strings 'mv "$staged_app_bundle" "$app_bundle"' \
        "$project_root/script/build_and_run.sh" \
    || ! rg -q --fixed-strings 'mv "$rollback_app_bundle" "$app_bundle"' \
        "$project_root/script/build_and_run.sh" \
    || ! rg -q --fixed-strings 'SPOTTY_DEVELOPMENT_SIGNING_IDENTITY' \
        "$project_root/Scripts/package-app.sh" \
    || ! rg -q --fixed-strings 'TeamIdentifier=' "$project_root/Scripts/validate-app.sh" \
    || ! rg -q --fixed-strings "codesign --verify --strict -R '=anchor apple generic'" \
        "$project_root/Scripts/validate-app.sh"; then
    print -u2 "Authenticated development signing policy is incomplete"
    exit 1
fi

if find "$project_root/Sources/Spotty" -type d -name LogicChecks -print -quit | rg -q .; then
    print -u2 "Logic tests must live in Spotty's non-shipping test targets, not the app target"
    exit 1
fi

# SwiftPM tests live under the conventional Tests/ hierarchy. Keep the old source-layout names
# from quietly returning: a source target would put deterministic checks back on the shipping
# module's input path and make the domain/boundary split harder to inspect.
if find "$project_root/Sources" -type d \( -name SpottyChecks -o -name DeferredBoundaryChecks \) -print -quit | rg -q .; then
    print -u2 "Swift tests must live under Tests/SpottyDomainTests and Tests/SpottyBoundaryTests"
    exit 1
fi
if [[ ! -d "$project_root/Tests/SpottyDomainTests" || ! -d "$project_root/Tests/SpottyBoundaryTests" ]]; then
    print -u2 "Conventional Swift test directories are missing"
    exit 1
fi

if rg -n "MockCatalog|PlaybackController|demo catalog" \
    "$project_root/Sources" "$project_root/README.md"; then
    print -u2 "Mock catalog references remain"
    exit 1
fi

# Public-repository hygiene. Generated bundles, archives, diagnostics, and finder metadata must
# never become source inputs or silently return in a later commit.
if git -C "$project_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    tracked_artifacts="$(git -C "$project_root" ls-files \
        | rg '(^|/)(\.DS_Store|Spotty\.app/|diagnostics/|dist/)|\.a$' || true)"
    if [[ -n "$tracked_artifacts" ]]; then
        print -u2 "Generated or private artifacts are tracked:"
        print -u2 "$tracked_artifacts"
        exit 1
    fi
fi

if rg -n 'security@example\.com|replace this placeholder' \
    "$project_root/README.md" \
    "$project_root/SECURITY.md" \
    "$project_root/CONTRIBUTING.md"; then
    print -u2 "A public-facing security-contact placeholder remains"
    exit 1
fi

# App-only entry points must remain usable with the Rust toolchain completely absent. The CI Swift
# and release lanes also install executable traps for these names; keep this source check close to
# the runtime trap contract so a new indirect source-engine/archive path cannot bypass it.
swift_entrypoints=(
    "$project_root/Scripts/compile-release-spotty.sh"
    "$project_root/Scripts/package-app.sh"
    "$project_root/Scripts/report-size.sh"
    "$project_root/Scripts/playback-xcframework.sh"
    "$project_root/Scripts/swiftpm-env.sh"
)
if rg -n '(^|[^[:alnum:]_])(cargo|rustc|rustup|cbindgen)([^[:alnum:]_]|$)|Backend/lib|libspotty_playback' \
    "${swift_entrypoints[@]}"; then
    print -u2 "App build, packaging, and size entry points must not invoke or consume Rust artifacts"
    exit 1
fi

# The CI quality gates must keep using an existing runner rg, immutable playback inputs,
# job-local SwiftPM caches, Rust-free Swift lanes, and credential-free checkouts.
ci_workflow="$project_root/.github/workflows/ci.yml"
if [[ ! -f "$ci_workflow" ]]; then
    print -u2 "CI workflow is missing"
    exit 1
fi
if ! rg -q 'command -v rg' "$ci_workflow"; then
    print -u2 "CI must use an existing rg before Homebrew ripgrep"
    exit 1
fi
if ! rg -q 'brew install ripgrep' "$ci_workflow"; then
    print -u2 "CI must still install ripgrep when the runner has no rg"
    exit 1
fi
if rg -q 'brew install swift-format|brew install swiftlint' "$ci_workflow"; then
    print -u2 "CI must use the selected toolchain swift-format, not a Homebrew Swift linter"
    exit 1
fi
policy_job="$(sed -n '/^  policy:/,/^  rust:/p' "$ci_workflow")"
rust_job="$(sed -n '/^  rust:/,/^  checks:/p' "$ci_workflow")"
checks_job="$(sed -n '/^  checks:/,/^  release:/p' "$ci_workflow")"
release_job="$(sed -n '/^  release:/,/^  gate:/p' "$ci_workflow")"
gate_job="$(sed -n '/^  gate:/,$p' "$ci_workflow")"
if grep -Eq '^[[:space:]]*([^#[:space:]].*)?SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK(=|[[:space:]]*:)' <<< "$checks_job$release_job"; then
    print -u2 "Swift CI must consume the published playback pin, not an unpublished engine override"
    exit 1
fi
checkout_without_credentials=$'uses: actions/checkout@[0-9a-f]{40} # v[^\n]+\n        with:\n          persist-credentials: false'
blocked_rust_tools=$'for tool in cargo rustc rustup cbindgen; do\n'
if ! rg -U -q "$checkout_without_credentials" <<< "$policy_job" \
    || ! rg -q 'uses: ast-grep/action@[0-9a-f]{40} # v' <<< "$policy_job" \
    || ! rg -q --fixed-strings 'paths: Sources Backend/spotty-playback/src' <<< "$policy_job" \
    || ! rg -q --fixed-strings '"$ast_grep" scan --config sgconfig.yml Sources Backend/spotty-playback/src' Scripts/check-source-policy.sh \
    || ! rg -q --fixed-strings 'run: ./Scripts/check-source-policy.sh --test-only' <<< "$policy_job" \
    || ! rg -q --fixed-strings 'runs-on: macos-26' <<< "$rust_job" \
    || ! rg -q --fixed-strings 'name: Rust checks' <<< "$rust_job" \
    || ! rg -q --fixed-strings 'needs: [policy]' <<< "$rust_job" \
    || ! rg -q --fixed-strings "if: needs.policy.outputs.rust_needed == 'true'" <<< "$rust_job" \
    || ! rg -q --fixed-strings 'git show "$INPUT_BASE_SHA:Scripts/ci_rust_policy.py" > "$trusted_policy"' <<< "$policy_job" \
    || ! rg -q --fixed-strings 'python3 "$trusted_policy" --event "$EVENT_NAME" --base "$INPUT_BASE_SHA"' <<< "$policy_job" \
    || ! rg -q --fixed-strings -- "-p 'test_*policy.py'" Scripts/check-source-policy.sh \
    || ! rg -q --fixed-strings 'candidate_needed' <<< "$rust_job" \
    || ! rg -q --fixed-strings 'run: ./Scripts/playback-candidate-needed.sh' <<< "$rust_job" \
    || ! rg -q --fixed-strings 'INPUT_BASE_SHA: ${{ github.event.pull_request.base.sha || github.event.before }}' <<< "$rust_job" \
    || ! rg -U -q "$checkout_without_credentials" <<< "$rust_job" \
    || ! rg -q 'key: macos-rust-.*Cargo\.lock' <<< "$rust_job" \
    || ! rg -q --fixed-strings 'source-input-digest.sh' Scripts/playback-candidate-needed.sh \
    || ! rg -q --fixed-strings 'run: SPOTTY_CHECK_SCOPE=rust ./Scripts/check.sh' <<< "$rust_job" \
    || ! rg -q --fixed-strings 'runs-on: macos-26' <<< "$checks_job" \
    || ! rg -q --fixed-strings 'xcode-select -s /Applications/Xcode_26.6.app' <<< "$checks_job" \
    || ! rg -q --fixed-strings "grep -q 'Apple Swift version 6.3.3'" <<< "$checks_job" \
    || ! rg -U -q "$checkout_without_credentials" <<< "$checks_job" \
    || ! rg -U -q --fixed-strings -- "$blocked_rust_tools" <<< "$checks_job" \
    || ! rg -q 'key: macos-swiftpm-debug-.*Package\.swift' <<< "$checks_job" \
    || ! rg -U -q --fixed-strings -- $'- name: Run checks\n        run: SPOTTY_CHECK_SCOPE=swift ./Scripts/check.sh' <<< "$checks_job" \
    || ! rg -q --fixed-strings 'runs-on: macos-26' <<< "$release_job" \
    || ! rg -q --fixed-strings 'xcode-select -s /Applications/Xcode_26.6.app' <<< "$release_job" \
    || ! rg -q --fixed-strings "grep -q 'Apple Swift version 6.3.3'" <<< "$release_job" \
    || ! rg -U -q "$checkout_without_credentials" <<< "$release_job" \
    || ! rg -U -q --fixed-strings -- "$blocked_rust_tools" <<< "$release_job" \
    || ! rg -q 'key: macos-swiftpm-release-.*Package\.swift' <<< "$release_job" \
    || ! rg -U -q --fixed-strings -- $'- name: Compile release Spotty with SPOTTY_DISTRIBUTION\n        run: ./Scripts/compile-release-spotty.sh' <<< "$release_job" \
    || ! rg -q --fixed-strings 'report-size.sh' <<< "$release_job" \
    || ! rg -q --fixed-strings 'if: always()' <<< "$gate_job" \
    || ! rg -q --fixed-strings 'needs: [policy, rust, checks, release]' <<< "$gate_job" \
    || ! rg -U -q --fixed-strings -- $'if [[ "$RUST_NEEDED" == true ]]; then\n            test "$RUST_RESULT" = success\n          else\n            test "$RUST_NEEDED" = false\n            test "$RUST_RESULT" = skipped\n          fi\n          test "$CHECKS_RESULT" = success' <<< "$gate_job" \
    || ! rg -q --fixed-strings 'test "$POLICY_RESULT" = success' <<< "$gate_job" \
    || ! rg -q --fixed-strings 'test "$RELEASE_RESULT" = success' <<< "$gate_job"; then
    print -u2 "CI must cache immutable inputs, block Rust in Swift lanes, and aggregate all quality lanes"
    exit 1
fi

plutil -lint "$project_root/Packaging/Info.plist"

bundle_plist="$project_root/Packaging/Info.plist"
if ! bundle_display_name="$(plutil -extract CFBundleDisplayName raw -o - "$bundle_plist")" \
    || ! bundle_name="$(plutil -extract CFBundleName raw -o - "$bundle_plist")" \
    || ! bundle_executable="$(plutil -extract CFBundleExecutable raw -o - "$bundle_plist")" \
    || ! bundle_icon_name="$(plutil -extract CFBundleIconName raw -o - "$bundle_plist")" \
    || ! bundle_icon="$(plutil -extract CFBundleIconFile raw -o - "$bundle_plist")" \
    || ! bundle_identifier="$(plutil -extract CFBundleIdentifier raw -o - "$bundle_plist")"; then
    print -u2 "Packaging Info.plist is missing a required bundle identity key"
    exit 1
fi
if [[ "$bundle_display_name" != "Spotty" \
    || "$bundle_name" != "Spotty" \
    || "$bundle_executable" != "Spotty" \
    || "$bundle_icon_name" != "Spotty" \
    || "$bundle_icon" != "Spotty" \
    || "$bundle_identifier" != "dev.spotty.app" ]]; then
    print -u2 "Packaging Info.plist must expose Spotty while preserving the Spotty executable, icon, and bundle identifier"
    print -u2 "display=$bundle_display_name name=$bundle_name executable=$bundle_executable icon_name=$bundle_icon_name icon_file=$bundle_icon identifier=$bundle_identifier"
    exit 1
fi

if [[ "$check_scope" == swift ]]; then
    print "Spotty Swift checks passed ($build_configuration): format, ABI, native app, domain, concrete boundary, architecture, and packaging checks are green"
else
    print "Spotty checks passed ($build_configuration): format, Rust, ABI, native app, domain, concrete boundary, architecture, and packaging checks are green"
fi
