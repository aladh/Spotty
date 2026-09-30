#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
build_configuration="${SPOTTY_BUILD_CONFIGURATION:-debug}"
check_scope="${SPOTTY_CHECK_SCOPE:-full}"
check_phase="${SPOTTY_CHECK_PHASE:-all}"
source "$project_root/Scripts/ci-timings.sh"
trap 'spotty_ci_timings_finish "$?"' EXIT
if [[ -n "${SPOTTY_CI_TIMINGS_REPORT:-}" && -n "${ZSH_VERSION:-}" ]]; then
    # zsh can exit inside a shell function without reaching its global EXIT trap.
    trap 'spotty_ci_timings_finish "$?"' ZERR
fi
spotty_ci_timings_start verification.environment
source "$project_root/Scripts/swiftpm-env.sh"
source "$project_root/Scripts/playback-xcframework.sh"
spotty_ci_timings_finish 0

case "$build_configuration" in
    debug|release) ;;
    *)
        print -u2 "SPOTTY_BUILD_CONFIGURATION must be debug or release"
        exit 2
        ;;
esac
case "$check_scope" in
    full|rust|rust-compiled|swift|swift-compiled) ;;
    *)
        print -u2 "SPOTTY_CHECK_SCOPE must be full, rust, rust-compiled, swift, or swift-compiled"
        exit 2
        ;;
esac

case "$check_phase" in
    all|contracts|tests) ;;
    *) print -u2 "SPOTTY_CHECK_PHASE must be all, contracts, or tests"; exit 2 ;;
esac
if [[ "$check_phase" != all && "$check_scope" != swift-compiled ]]; then
    print -u2 "Partitioned phases require CI's swift-compiled scope; normal gates stay complete"
    exit 2
fi

if [[ "$check_scope" == full ]]; then
    spotty_ci_timings_start verification.source-policy
    "$project_root/Scripts/check-source-policy.sh"
    spotty_ci_timings_finish 0
fi

# Normal local scopes retain portable checks; CI's compiled scopes run them on Linux.
if [[ "$check_scope" != rust-compiled && "$check_scope" != swift-compiled ]]; then
    spotty_ci_timings_start verification.script-harness
    python3 -B "$project_root/Scripts/script_tests.py" harness
    spotty_ci_timings_finish 0
fi

# Fail fast on Swift format drift before Rust or Swift compilation.
# The sibling self-test covers wrapper discovery/failure contracts without a Swift toolchain.
if [[ "$check_scope" != rust && "$check_scope" != rust-compiled && "$check_phase" != tests ]]; then
    if [[ "$check_scope" != swift-compiled ]]; then
        spotty_ci_timings_start verification.watchdog-and-format-contracts
        python3 -B "$project_root/Scripts/script_tests.py" watchdog
        "$project_root/Scripts/format-swift-self-test.sh"
        spotty_ci_timings_finish 0
    fi
    spotty_ci_timings_start swift.format
    "$project_root/Scripts/format-swift.sh" --check
    spotty_ci_timings_finish 0

    # Keep Launch Services, update eligibility, icons, and compiler probes aligned with SwiftPM.
    spotty_ci_timings_start swift.package-graphs
    minimum_macos="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$project_root/Packaging/Info.plist")"
    package_minimum_macos="$(python3 "$project_root/Scripts/check-package-graphs.py")"
    engine_minimum_macos="$(cat "$project_root/Backend/spotty-playback/macos-deployment-target")"
    if [[ "$minimum_macos" != "$engine_minimum_macos" ]]; then
        print -u2 "App minimum macOS ($minimum_macos) must match the engine producer ($engine_minimum_macos)"
        exit 1
    fi
    if [[ "$minimum_macos" != "$package_minimum_macos" ]]; then
        print -u2 "Packaging minimum macOS ($minimum_macos) must match SwiftPM ($package_minimum_macos)"
        exit 1
    fi
    spotty_ci_timings_finish 0
fi

# The Rust suite owns lifecycle, generation, queue conversion, typed C snapshots,
# source-header reproducibility, and compile-time C signature checks. Prefer the
# developer's normal toolchain; the fallback is the project-local toolchain
# provisioned by the development bootstrap on this workspace.
if [[ "$check_scope" != swift && "$check_scope" != swift-compiled ]]; then
    # CI runs these portable source-level checks in parallel on Linux. Full and normal Rust
    # verification retain them so local aggregate behavior remains unchanged.
    if [[ "$check_scope" != rust-compiled ]]; then
        spotty_ci_timings_start rust.script-contracts
        python3 -B "$project_root/Scripts/script_tests.py" playback
        spotty_ci_timings_finish 0
    fi
    spotty_ci_timings_start rust.header-reproducibility
    "$project_root/Scripts/generate-c-header.sh" --check
    spotty_ci_timings_finish 0

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

    spotty_ci_timings_start rust.format
    "$cargo_bin" fmt --all --manifest-path "$project_root/Backend/spotty-playback/Cargo.toml" -- --check
    spotty_ci_timings_finish 0
    spotty_ci_timings_start rust.clippy
    "$cargo_bin" clippy --locked --manifest-path "$project_root/Backend/spotty-playback/Cargo.toml" \
        --all-targets -- -D warnings
    spotty_ci_timings_finish 0
    spotty_ci_timings_start rust.tests.bridge
    "$cargo_bin" test --locked --manifest-path "$project_root/Backend/spotty-playback/Cargo.toml"
    spotty_ci_timings_finish 0
    spotty_ci_timings_start rust.tests.retained-librespot
    "$cargo_bin" test --locked --manifest-path "$project_root/Backend/spotty-playback/Cargo.toml" \
        -p librespot-core -p librespot-connect -p librespot-playback --lib spotty_
    spotty_ci_timings_finish 0

    if [[ "$check_scope" == rust || "$check_scope" == rust-compiled ]]; then
        print "Spotty Rust checks passed: formatting, warning-clean clippy, and locked tests are green"
        exit 0
    fi
fi

# Resolve one immutable playback artifact and keep all C/ABI checks paired with the headers
# shipped beside its selected archive. The SwiftPM resolver owns remote downloads; a source-built
# engine must be selected explicitly with SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK.
spotty_ci_timings_start swift.artifact.resolve
selected_xcframework="$(spotty_playback_resolve_xcframework)"
spotty_ci_timings_finish 0
spotty_ci_timings_start swift.artifact.validate
spotty_playback_validate_xcframework "$selected_xcframework"
if [[ -z "${SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK:-}" ]]; then
    python3 "$project_root/Scripts/check-playback-freshness.py" "$selected_xcframework"
fi
playback_slice="$(spotty_playback_slice_path "$selected_xcframework")"
playback_archive="$(spotty_playback_archive_path "$playback_slice")"
playback_headers="$(spotty_playback_headers_path "$playback_slice")"
spotty_ci_timings_finish 0
python3 "$project_root/Scripts/playback_module_cache.py" "$project_root/.build" "$playback_headers" \
    --configuration "$build_configuration"
if [[ "$check_phase" != tests ]]; then
    spotty_ci_timings_start swift.abi.import
    "$project_root/Scripts/check-c-header-imports.sh" "$playback_headers"
    spotty_ci_timings_finish 0
    playback_header="$playback_headers/spotty_playback.h"

    # Keep the selected artifact's C header and its static-library exports in exact
    # agreement. Apple's nm can warn on newer Rust LLVM attributes in unrelated
    # compiler-builtins objects, but it still emits the defined Spotty symbols; the
    # exact set comparison below is the contract check.
    spotty_ci_timings_start swift.abi.exports
    header_symbols="$(mktemp /tmp/spotty-header-symbols.XXXXXX)"
    header_symbol_declarations="$(mktemp /tmp/spotty-header-symbol-declarations.XXXXXX)"
    library_symbols="$(mktemp /tmp/spotty-library-symbols.XXXXXX)"
    header_ast="$(mktemp /tmp/spotty-header-ast.XXXXXX)"
    trap 'spotty_ci_timings_finish "$?"; rm -f "$header_symbols" "$header_symbol_declarations" "$library_symbols" "$header_ast"' EXIT

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

    # Retired exports may remain in an older pin. Shared producer/selected exports still require
    # a call, and every call must exist in the selected artifact, independently of new producer APIs.
    source "$project_root/Scripts/abi-signature-fixture.sh"
    spotty_abi_check_consumption "$header_symbols" \
        "$project_root/Sources/SpottyEngineAdapter/PlaybackCore.swift" \
        "$project_root/Backend/spotty-playback/abi-signatures.txt"
    spotty_ci_timings_finish 0

    swift_arguments=(
        --disable-sandbox
        --package-path "$project_root"
        --configuration "$build_configuration"
        --product Spotty
    )
    # SwiftPM owns relinking. The selected artifact's content-addressed library filename changes
    # with the engine, including when a source-built local override reuses its XCFramework directory.
    if [[ -n "${SPOTTY_SIGNING_IDENTITY:-}" ]]; then
        swift_arguments+=(-Xswiftc -DSPOTTY_DISTRIBUTION)
    fi
    swift_arguments+=("${spotty_swiftc_warnings_as_errors[@]}")

    spotty_ci_timings_start "swift.shipping-$build_configuration.build"
    SPOTTY_BUILD_BROWSING_HARNESS=0 swift build "${swift_arguments[@]}"
    spotty_ci_timings_finish 0
fi

if [[ "$check_phase" != contracts ]]; then
    repeat_count="${SPOTTY_CHECK_REPEATS:-1}"
    if ! [[ "$repeat_count" =~ '^[1-9][0-9]*$' ]] || (( repeat_count > 25 )); then
        print -u2 "SPOTTY_CHECK_REPEATS must be between 1 and 25"
        exit 2
    fi
    if [[ -n "${SPOTTY_SWIFT_TEST_TIMEOUT_SECONDS:-}" ]]; then
        swift_test_timeout="$SPOTTY_SWIFT_TEST_TIMEOUT_SECONDS"
    elif [[ -n "${CI:-}" ]]; then
        swift_test_timeout=300
    else
        # Cold local compiles can legitimately exceed the warm CI test-invocation budget.
        swift_test_timeout=1200
    fi
    if [[ -n "${RUNNER_TEMP:-}" ]]; then
        swift_test_diagnostics="${SPOTTY_SWIFT_TEST_DIAGNOSTICS_DIR:-$RUNNER_TEMP/spotty-swift-test-diagnostics}"
    else
        swift_test_diagnostics="${SPOTTY_SWIFT_TEST_DIAGNOSTICS_DIR:-${TMPDIR:-/tmp}/spotty-swift-test-diagnostics-$$}"
    fi
    mkdir -p "$swift_test_diagnostics"
    # Build one complete Debug test graph, including the opt-in browsing harness. An unfiltered
    # invocation automatically covers new test targets. Keep shipping compilation above separate;
    # testability and synthetic dependencies never change the production graph.
    run_swift_tests() {
        local lane="$1" configuration="$2"
        shift 2
        local package_graph=full
        local package_root="$project_root"
        local graph_arguments=()
        if [[ "$lane" == domain-release ]]; then
            spotty_ci_timings_start swift.test-package-graph.domain-release
            package_graph=domain
            package_root="$(python3 "$project_root/Scripts/verification_package.py" domain)"
            graph_arguments=(--scratch-path "$project_root/.build/domain")
            spotty_ci_timings_finish 0
        fi
        local run
        for (( run = 1; run <= repeat_count; run++ )); do
            spotty_ci_timings_start "swift.tests.$lane.repeat-$run" \
                "$swift_test_diagnostics/$lane-repeat-$run.log" \
                "$swift_test_diagnostics/$lane-repeat-$run-events.jsonl"
            SPOTTY_BUILD_BROWSING_HARNESS=$([[ "$configuration" == debug ]] && print 1 || print 0) \
                SPOTTY_PACKAGE_GRAPH="$package_graph" \
                python3 "$project_root/Scripts/swift_test_watchdog.py" \
                --lane "$lane" --repetition "$run" --timeout-seconds "$swift_test_timeout" \
                --log-dir "$swift_test_diagnostics" \
                --require-tests \
                --event-stream-path "$swift_test_diagnostics/$lane-repeat-$run-events.jsonl" \
                -- swift test --disable-sandbox --no-parallel --package-path "$package_root" \
                --configuration "$configuration" "${graph_arguments[@]}" "${spotty_swiftc_warnings_as_errors[@]}" "$@"
            spotty_ci_timings_finish 0
        done
    }
    # Release verification retains optimized pure-policy coverage. Concrete boundaries require Debug
    # @testable modules; production code is never compiled with testability enabled for this purpose.
    if [[ "$build_configuration" == release ]]; then
        run_swift_tests domain-release release --filter SpottyDomainTests
    fi
    run_swift_tests debug debug
fi

if [[ "$check_phase" != tests ]]; then
    spotty_ci_timings_start swift.contracts.projection-compiler
    "$project_root/Scripts/check-playback-projection-access.sh"
    spotty_ci_timings_finish 0

    spotty_ci_timings_start swift.contracts.packaging-and-layout
    if find "$project_root/Sources/Spotty" -type d -name LogicChecks -print -quit | rg -q .; then
        print -u2 "Logic tests must live in Spotty's non-shipping test targets, not the app target"
        exit 1
    fi

    # SwiftPM tests live under the conventional Tests/ hierarchy. Keep the old source-layout names
    # from quietly returning: a source target would put deterministic checks back on the shipping
    # module's input path and make the domain/boundary split harder to inspect.
    if find "$project_root/Sources" -type d \( -name SpottyChecks -o -name DeferredBoundaryChecks \) -print -quit | rg -q .; then
        print -u2 "Swift tests must live under conventional Tests/ directories"
        exit 1
    fi
    for test_target in SpottyDomainTests SpottyBoundaryTests SpottyCatalogStorageTests \
        SpottySessionRuntimeTests SpottyGatewayTests SpottyTestSupportTests SpottyEngineAdapterTests; do
        if [[ ! -d "$project_root/Tests/$test_target" ]]; then
            print -u2 "Conventional Swift test directory is missing: Tests/$test_target"
            exit 1
        fi
    done


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


    ruby "$project_root/Scripts/check-ci-workflow.rb" "$project_root/.github/workflows/ci.yml"

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
    spotty_ci_timings_finish 0
fi

if [[ "$check_phase" == contracts ]]; then
    print "Spotty Swift contracts passed: format, package graphs, ABI, shipping Debug, compiler and packaging"
elif [[ "$check_phase" == tests ]]; then
    print "Spotty Swift test checks passed: selected artifact and complete native test graph"
elif [[ "$check_scope" == swift || "$check_scope" == swift-compiled ]]; then
    print "Spotty Swift checks passed ($build_configuration): format, ABI, native app, domain, concrete boundary, architecture, and packaging checks are green"
else
    print "Spotty checks passed ($build_configuration): format, Rust, ABI, native app, domain, concrete boundary, architecture, and packaging checks are green"
fi
