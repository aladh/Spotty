# Build and verification

[Setup](setup.md) · [Contribution workflow](../../CONTRIBUTING.md) · Run from the repository root.

## Normal verification

Use focused checks, then relevant gates. Documentation-only edits need no build.

| `python3 Scripts/verify.py …` | Use for |
| --- | --- |
| `preflight` | Discover tools without running or installing them |
| `list` | Discover Swift tests, including the synthetic harness |
| `test --filter SpottyBoundaryTests.PlaybackPositionSliderChecks` | Native controls (full graph) |
| `test --target SpottyGatewayTests --filter KeymasterPersistence` | Grant persistence (engine free) |
| `test --target SpottyTestSupportTests` | Clocks, response gates, polling (engine free) |
| `test --target SpottyEngineAdapterTests` | Snapshot decoding, event delivery, reconnect |
| `test --target SpottySessionRuntimeTests` | Headless runtime without desktop dependencies |
| `domain --filter PlaybackReducer` | Domain-only tests, without app or engine dependencies |
| `swift` | Swift, ABI, compiler boundaries, packaging, and synthetic helpers; no Rust needed |
| `rust` | Compiled Rust, headers, and playback/harness helpers |
| `harness` | Synthetic browsing, measurement, and trace helper scripts |
| `source` | Source, topology, documentation, and script policies |
| `check` | Complete normal gate |
| `clean` | Rebuild the engine and run complete Debug/Release verification |

`list` and `test` forward SwiftPM arguments using the gate's SDK, caches, and warning policy.
Place `--target MODULE` or `--target=MODULE` immediately after `test`/`list` on Swift 6.3.3/6.4.
It selects one test module's dependency closure. Multiple filters retain SwiftPM union semantics.
Use `--skip-build` only with unchanged sources, graph, configuration, flags and artifacts.
Empty or entirely skipped selections fail. Count executed tests from completion events;
Swift's summary includes skipped probes.

Select Domain, TestSupport, CatalogStorage, Gateway, EngineAdapter, SessionRuntime or Boundary tests.
The first four are engine free; Adapter/Runtime need playback, Boundary also needs Sparkle.
`.build/test-targets/MODULE/package` links declarations and owns its lock; its parent owns scratch.
The app lock stays unchanged. Selected scratch paths stay literal; package-path/test-product combinations fail.
Selected listing/help requires no execution. Without a selector, explicit paths retain the caller's
graph; legacy target-named products require Swift 6.4. Full gates/shipping keep the full graph.
`domain` remains portable under `.build/domain`.

`domain` forwards Release options. Full Debug includes every target and browsing; Release adds
optimized domain checks. Boundaries use Debug `@testable`; shipping excludes harness targets.
Queue scheduler suspension hooks and SessionRuntime admission/mutation checks are Debug-only.
Pure Domain queue-mutation policy also runs optimized.

Complete gates use [check.sh](../../Scripts/check.sh),
[source policies](../../Scripts/check-source-policy.sh), and [check-clean.sh](../../Scripts/check-clean.sh).
Direct `check.sh` calls accept `SPOTTY_CHECK_SCOPE=swift` or `rust`. Internal CI `swift-compiled`
phases divide contracts and complete native tests between jobs; normal gates force the complete
phase. Checks do not sign in or start playback. A source/pin mismatch warns without replacing the
published engine.

All gates need Python 3.10+. Swift/source gates need Ruby; source policies also need Node.js 20+,
npm, jq, and the version in `Scripts/ast-grep/version`. Install reviewer test dependencies with
`npm ci --ignore-scripts --prefix Scripts/agent-review-tests`. If the pinned ast-grep is unavailable:

```bash
npm install --prefix /tmp/spotty-ast-grep "@ast-grep/cli@$(cat Scripts/ast-grep/version)"
SPOTTY_AST_GREP=/tmp/spotty-ast-grep/node_modules/.bin/ast-grep python3 Scripts/verify.py source
```

Rust gates additionally need the [engine toolchain](setup.md#engine-development).
`SPOTTY_CARGO` and `SPOTTY_CBINDGEN` accept executable paths, resolved relative to the repository.
After changing Rust ABI declarations, run `./Scripts/generate-c-header.sh` and include its generated
header; use `--check` for reproducibility. Preserve [pointer ownership](../../Sources/SpottyPlaybackCore/AGENTS.md)
and extend the Swift import fixtures for new pointer shapes.

Format with `./Scripts/format-swift.sh --check` or `--write`; both include new/unstaged Swift files
and exclude ignored/deleted files. [Script discovery](../../Scripts/script_tests.py) routes Python/Node
suites. Python workers run independently (`--jobs 1` for serial diagnosis). Each file and the Node
invocation has a 120-second deadline (`--timeout-seconds`); timeout/interruption cleans owned process
groups. Logs retain bounded tails. See [proof limits](../architecture/enforcement.md) and
[CI selection](../architecture/enforcement/build-and-abi.md#ci-and-release-workflow).

For justified lifetime stress, set `SPOTTY_CHECK_REPEATS=N` (1–25); main runs three passes.
The [watchdog](../../Scripts/swift_test_watchdog.py) bounds each Swift test invocation to five minutes
in CI or twenty locally, sampling and terminating only its own process tree without retry.
Override with `SPOTTY_SWIFT_TEST_TIMEOUT_SECONDS`; select an artifact directory with
`SPOTTY_SWIFT_TEST_DIAGNOSTICS_DIR`. The wrapper reports commands, status, and diagnostics paths;
CI retains Debug invocation logs and supported native event streams, including passing runs.

## Deterministic synchronization

[SpottyTestSupport](../../Tests/SpottyTestSupport) is shared by desktop and headless tests without
depending on either implementation. Use `HarnessClock.scheduled()` for elapsed-time behavior:
establish the expected `waiterCount`, advance to before the deadline, then cross it. Advancing wakes
due sleepers; await their observable effects before advancing through another scheduling cycle.
Parked clocks are explicit barriers and wake only through release or cancellation.

Use `HarnessResponseGate<Value>` for suspended responses. Cancellation is cooperative by default;
choose `.ignored` for late results. Close gates in `defer` and cancel owned tasks. Closing releases
pending and future callers; early replies are retained.
Require `try await requireEventually(description: …)` before releasing or joining work. Polling
preserves actor isolation and call-site diagnostics, with bounded backoff. Predicates must return
promptly. The timeout bounds observation, not simulated time; the process watchdog covers stalled
actors or dependencies.

Runtime command scenarios share [CommandRuntimeFixture](../../Tests/SpottySessionRuntimeTests/CommandRuntimeFixture.swift)
for synchronous effect capture, numbered dependency replies, and teardown. Keep setup and outcome
assertions in each suite. Close additional gates through `closing` before cleanup joins them.
Desktop delivery checks read only published properties after a reply; compatibility runtime reads
and effect waits force a snapshot refresh and can conceal broken subscriptions.

## Clean and risk-specific verification

Reserve `clean` for work requiring a clean rebuild. It removes generated Swift products and rebuilds
the engine; install the full toolchain first. Use `./Scripts/compile-release-spotty.sh` for compile-only
Release verification.

## Build and run

For an authorized launch, use `./script/build_and_run.sh`. It validates a signed bundle before
replacing the development app. Follow [launch constraints](../../script/AGENTS.md) and
[signing setup](signing.md). Its `--verify` and `--verify-release` modes check process launch;
they do not run the verification gates.

## Diagnostics

`./Scripts/export-diagnostics.sh [lookback]` exports Unified Logging to ignored `diagnostics/`
(default `15m`) without pruning it. Handle reports under [PRIVACY.md](../../PRIVACY.md).

## Synthetic browsing

Use `./script/build_and_run.sh --demo` for interactive fixtures or `./Scripts/browse-synthetic.sh`
for an automated workload. Both use the separately signed, network-denied Demo under
[standing authorization](../product/safe-testing.md#spotty-demo-standing-authorization).
Close the Demo when finished. Follow [synthetic acceptance](synthetic-acceptance.md) for scenario
selection, fault injection, evidence, and Accessibility smoke checks; follow the
[visual fidelity contract](../product/scope.md#visual-fidelity-and-interaction) for UI changes.

### Combined hydration and lifecycle measurements

Use [runtime measurements](runtime-acceptance.md#measurements) for optimized comparisons,
Instruments captures, and credential-free lifecycle checks.
