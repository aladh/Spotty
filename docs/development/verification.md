# Build and verification

[Agent operations](../../CONTRIBUTING.md) · Run commands from the repository root.

## Build and run

For an authorized launch:

```bash
./script/build_and_run.sh
```

This verifies, builds, signs, and replaces the running app. For compile-only work, use the checks
below. Launch modes include `--debug`, `--logs`, `--telemetry`, `--verify`, `--release`, and
`--verify-release`; follow the [launch constraints](../../script/AGENTS.md) and [signing setup](signing.md).

## Normal verification

Choose the smallest check that covers the change. Documentation-only edits need no app build.
UI work also follows [visual fidelity](../product/scope.md#visual-fidelity-and-interaction) and
[Demo/Spotify inspection permissions](../product/safe-testing.md).

| Command | Coverage |
| --- | --- |
| `./Scripts/check.sh` | Complete gate, including source policies |
| `./Scripts/check-source-policy.sh` | Source, topology, and documentation policies |
| `SPOTTY_CHECK_SCOPE=swift ./Scripts/check.sh` | Swift checks against the published engine pin |
| `SPOTTY_CHECK_SCOPE=rust ./Scripts/check.sh` | Python playback checks and compiled Rust/header checks |

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

[Script-test discovery](../../Scripts/script_tests.py) owns Python and Node suite routing for local
and CI gates. Name Python tests `test_*.py`, `*_test.py`, or `test.py`; keep helpers outside those
names. New top-level Python tests in `Scripts/` join the policy lane unless playback or watchdog owns them.
Review tests live directly in `Scripts/agent-review-tests/`. Recognized test
files outside these owners and empty suites fail instead of being silently skipped.

CI runs source policies, Python playback checks, and the Linux domain job before its single macOS
job. Documentation-only PRs skip macOS. App-only PRs can skip compiled Rust; main runs it.
Unknown paths and classification errors cannot authorize a skip. The trusted base classifier,
complete aggregate, caches, and exact workflow behavior belong to
[CI enforcement](../architecture/enforcement/build-and-abi.md#ci-and-release-workflow),
[CI policy](../../Scripts/ci_rust_policy.py), and [ci.yml](../../.github/workflows/ci.yml).

After changing a Rust ABI declaration, run `./Scripts/generate-c-header.sh` and commit the generated
header; never hand-edit it. Use `--check` for reproducibility and `SPOTTY_CBINDGEN` for an alternate
pinned executable. Preserve [pointer ownership](../../Sources/SpottyPlaybackCore/AGENTS.md) and
extend `Scripts/check-c-header-imports.sh` for new pointer shapes.

Format Swift with `./Scripts/format-swift.sh --check` or `--write`. Discover focused tests with
`swift test list`, then filter:

```bash
swift test --disable-sandbox --filter ProtobufTests/testProtobuf
swift test --disable-sandbox --no-parallel --filter AuthFlowTests/testAuthFlow
```

Set `SPOTTY_BUILD_BROWSING_HARNESS=1` to include harness targets; `check.sh` already does so.
ABI/compiler/source fixtures are script inputs, not Swift test targets. For justified lifetime
stress, use `SPOTTY_CHECK_REPEATS=N` (1–25); main runs three passes.

Each Swift test invocation has a process-group watchdog: five minutes in CI, twenty locally.
`SPOTTY_SWIFT_TEST_TIMEOUT_SECONDS` overrides the local limit for diagnosis. Timeout handling
samples and terminates only that invocation, without retrying it or killing unrelated processes.
CI uploads per-lane logs and supported Swift Testing event streams from
`$RUNNER_TEMP/spotty-swift-test-diagnostics` when Debug checks fail.

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

The isolated Demo uses the normal UI with synthetic dependencies, a verified network-denying
sandbox, and no live credentials, engine, or audio output. Its separate Apple Development-signed
identity is `dev.spotty.demo` at `.build/Spotty Demo.app`; caches/preferences persist separately
from live Spotty. Follow [standing authorization](../product/safe-testing.md#spotty-demo-standing-authorization).

[demo.json](../../Tests/BrowsingHarness/demo.json) supplies a scrolling playlist library and album/
artist edge cases, including missing artwork, empty results, long titles, and unavailable tracks.
Pass another scenario path for a bounded workload; `mode: "signed-out"` exercises sign-out UI.
Invalid scenarios fail closed. Each run writes fixtures and `report.json` under
`.build/browsing-runs/`; automated runs fail on workload failure or timeout and leave the Demo open.

### Synthetic playback and fault traces

`./Scripts/browse-synthetic.sh Tests/BrowsingHarness/playback.json` exercises transport and injected
faults through a synthetic playback authority. Add `--interactive` before the scenario to use its
Demo fault menu. Version-1 scenarios remain read-only; all harness targets stay outside the shipping
package graph. See [runtime acceptance](runtime-acceptance.md) for evidence limits.

### Combined hydration and lifecycle measurements

Use the [measurement procedure](runtime-acceptance.md#measurements) for optimized runs, Instruments
captures, queue hydration comparisons, and credential-free lifecycle measurements. Scenario
parameters live in [harness fixtures](../../Tests/BrowsingHarness); report fields and exact cases
belong to their producers and tests, not a second inventory here.
