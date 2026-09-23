# Build and verification

[Agent operations](../../CONTRIBUTING.md) · Run commands from the repository root.

## Build and run

For an authorized launch:

```bash
./script/build_and_run.sh
```

This builds and validates a signed bundle before replacing the running development app. Launch
modes include `--debug`, `--logs`, `--telemetry`, `--verify`, `--release`, and `--verify-release`;
follow the [launch constraints](../../script/AGENTS.md) and [signing setup](signing.md).
The `--verify` modes check that the process launches; use the verification gates below for tests
and compile-only work.

## Normal verification

Choose the smallest check that covers the change. Documentation-only edits need no app build.
UI work also follows [visual fidelity](../product/scope.md#visual-fidelity-and-interaction) and
[Demo/Spotify inspection permissions](../product/safe-testing.md).

Use [CONTRIBUTING's command table](../../CONTRIBUTING.md#verification-commands) for tool discovery,
focused Swift tests, language scopes, and complete gates. `SPOTTY_CHECK_SCOPE=swift` or `rust` also
selects the corresponding scope when invoking `check.sh` directly.

All scopes need Python 3. Full/Swift checks also need Ruby; full/Rust checks need the
[engine toolchain](setup.md#engine-development) and pinned cbindgen. Source policies also need Ruby,
Node.js 20+, npm, jq, and the ast-grep version in `Scripts/ast-grep/version`. Install reviewer test
dependencies with `npm ci --ignore-scripts --prefix Scripts/agent-review-tests`.
If Homebrew does not provide the pinned ast-grep version:

```bash
npm install --prefix /tmp/spotty-ast-grep "@ast-grep/cli@$(cat Scripts/ast-grep/version)"
SPOTTY_AST_GREP=/tmp/spotty-ast-grep/node_modules/.bin/ast-grep ./Scripts/check-source-policy.sh
```

Checks neither sign in nor start playback. A source/pin mismatch warns without rebuilding or
replacing the published engine. Packaging and Swift checks need no Rust tools.
[Source policies](../architecture/enforcement/source-checks.md) explain their proof limits;
[Package.swift](../../Package.swift) owns test targets and platform boundaries.

[Script-test discovery](../../Scripts/script_tests.py) owns Python/Node naming and suite routing;
unowned test files and empty suites fail. See [coverage enforcement](../architecture/enforcement/source-checks.md)
when adding a suite.

[CI enforcement](../architecture/enforcement/build-and-abi.md#ci-and-release-workflow) owns job order
and trusted skips: documentation-only PRs skip macOS; app-only PRs may skip compiled Rust; main
runs both toolchains.

After changing a Rust ABI declaration, run `./Scripts/generate-c-header.sh` and commit the generated
header; never hand-edit it. Use `--check` for reproducibility and `SPOTTY_CBINDGEN` for an alternate
pinned executable. Preserve [pointer ownership](../../Sources/SpottyPlaybackCore/AGENTS.md) and
extend `Scripts/check-c-header-imports.sh` for new pointer shapes.

Format Swift with `./Scripts/format-swift.sh --check` or `--write`. The `verify.py list/test` commands
and `check.sh` include harness targets; bare SwiftPM needs `SPOTTY_BUILD_BROWSING_HARNESS=1`.
ABI/compiler/source fixtures are script inputs. For justified lifetime stress, use
`SPOTTY_CHECK_REPEATS=N` (1–25); main runs three passes.

The [watchdog](../../Scripts/swift_test_watchdog.py) bounds each Swift test invocation to five minutes
in CI or twenty locally, sampling and terminating only that invocation without retry. For diagnosis,
set `SPOTTY_SWIFT_TEST_TIMEOUT_SECONDS` or `SPOTTY_SWIFT_TEST_DIAGNOSTICS_DIR`; `verify.py` reports
commands, exit status, and the artifact directory. CI uploads logs and supported native event streams
when Debug checks fail.

## Clean and risk-specific verification

Use `./Scripts/check-clean.sh` only when a clean rebuild is needed. It removes generated Swift
products, rebuilds the engine, and runs the full gate for Debug and Release. Preserve unrelated
work and install the full gate's tools first. `./Scripts/compile-release-spotty.sh` provides
compile-only Release verification.

## Diagnostics

`./Scripts/export-diagnostics.sh [lookback]` exports local Unified Logging to ignored
`diagnostics/` (default lookback: `15m`) without pruning it. Handle reports under [PRIVACY.md](../../PRIVACY.md).

## Synthetic browsing

```bash
./script/build_and_run.sh --demo   # Interactive browsing
./Scripts/browse-synthetic.sh      # Automated browsing workload
```

The Apple Development-signed Demo at `.build/Spotty Demo.app` uses synthetic dependencies, a
network-denying sandbox, and separate `dev.spotty.demo` state under
[standing authorization](../product/safe-testing.md#spotty-demo-standing-authorization).
[demo.json](../../Tests/BrowsingHarness/demo.json) supplies interactive fixtures; pass another
scenario path for a bounded workload. Invalid scenarios fail closed. Automated runs leave the Demo
open; close it when done. [Synthetic acceptance](synthetic-acceptance.md) owns named scenarios,
reports under `.build/browsing-runs/`, and early-failure diagnostics.

### Synthetic playback and fault traces

Pass `Tests/BrowsingHarness/playback.json` for synthetic transport and faults; add `--interactive`
for the Demo fault menu. Version-1 scenarios remain read-only. Harness targets are non-shipping.

### Semantic UI smoke

Follow [synthetic acceptance](synthetic-acceptance.md#semantic-ui-smoke) for the command, permission
preflight, and bounded Accessibility flow.

### Combined hydration and lifecycle measurements

Use the [measurement procedure](runtime-acceptance.md#measurements) for optimized runs, Instruments
captures, queue hydration comparisons, and credential-free lifecycle measurements.
