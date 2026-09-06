# Build and verification

[Agent operations](../../CONTRIBUTING.md) · Run commands from the repository root.

## Build and run

For an authorized launch, from the repository root:

```bash
./script/build_and_run.sh
```

This verifies, builds, signs, and replaces the running app; do not use it as a compile check.
Modes include `--verify`, `--release`, `--verify-release`, and `--telemetry`.
See [launch constraints](../../script/AGENTS.md) and
[signing setup](signing.md) before authenticated launches.

## Normal verification

Use the smallest focused check per [AGENTS.md](../../AGENTS.md#local-verification). Available gate scopes:

```bash
./Scripts/check.sh
./Scripts/check-source-policy.sh
SPOTTY_CHECK_SCOPE=swift ./Scripts/check.sh
SPOTTY_CHECK_SCOPE=rust ./Scripts/check.sh
```

The full gate includes source policies; CI runs those once in the Linux `Source policies` job,
separately from the Swift and Rust scopes. `check-source-policy.sh` needs Python 3 and ast-grep
at the version in `Scripts/ast-grep/version`. Install with `brew install ast-grep` when Homebrew
provides that version, or install the exact CLI with npm:

```bash
npm install --prefix /tmp/spotty-ast-grep "@ast-grep/cli@$(cat Scripts/ast-grep/version)"
SPOTTY_AST_GREP=/tmp/spotty-ast-grep/node_modules/.bin/ast-grep ./Scripts/check-source-policy.sh
```

[Source policies](../architecture/enforcement/source-checks.md) index the rules and their limits.
When changing a rule, cover syntax variants and file-owner exceptions. A clean syntax scan does
not replace Swift compilation or behavior tests.

The full and Rust scopes require the [engine toolchain](setup.md#engine-development).
The Swift scope and packaging use the pinned binary without Rust tools. Checks do not sign in or
initiate playback. See the [enforcement inventory](../architecture/enforcement.md) for coverage.

CI uses one macOS job for conditional Rust verification/candidate production, then Swift Debug
checks and the Release distribution compile. Debug and Release share one SwiftPM cache under a
new combined key; separate configuration directories remain inside `.build`. Rust tools are blocked
before Swift runs. Main requires `Source policies` and `macOS checks`. The final macOS step validates each phase
outcome, including the explicit decision required to skip Rust.

CI skips Rust only for PRs limited to app sources/tests, assets, packaging, package pins, or
documentation. Engine, shared-header, CI, script, license, and unknown paths require Rust; main always
runs it. The Linux source-policy job uses the PR base commit's classifier. A base without the policy
requires Rust, and detection errors fail the aggregate. Skipped Rust steps are accepted only after an
explicit successful app-only decision. See [CI policy](../../Scripts/ci_rust_policy.py) for exact paths.

After changing a Rust ABI declaration, run `./Scripts/generate-c-header.sh` and commit the generated
header. `--check` verifies reproducibility; set `SPOTTY_CBINDGEN` if the pinned tool is not on `PATH`.

Edit Rust declarations and regenerate; never hand-edit generated headers. Preserve callback and
pointer ownership annotations under the [C-boundary guidance](../../Sources/SpottyPlaybackCore/AGENTS.md).
Extend `Scripts/check-c-header-imports.sh` when adding a pointer shape.

Swift formatting:

```bash
./Scripts/format-swift.sh --check
./Scripts/format-swift.sh --write
```

Tests live in `Tests/SpottyDomainTests/` and `Tests/SpottyBoundaryTests/`. Discover names with
`swift test list`, then filter for focused iteration:

```bash
swift test --disable-sandbox --filter ProtobufTests/testProtobuf
swift test --disable-sandbox --no-parallel --filter AuthFlowTests/testAuthFlow
```

Use `SPOTTY_CHECK_REPEATS=N ./Scripts/check.sh` with `N` from 1 through 25 when concurrency or
lifetime work merits stress.

## Clean and risk-specific verification

For clean-build changes or diagnosis requiring a rebuild:

```bash
./Scripts/check-clean.sh
```

This removes generated Swift build products, rebuilds the engine artifact, and verifies Debug and
Release. Preserve unrelated work. Use `./Scripts/compile-release-spotty.sh` for compile-only Release
verification.

## Diagnostics

Release builds use Unified Logging. `./Scripts/export-diagnostics.sh` writes a bounded report under
ignored `diagnostics/`. Handle reports according to [PRIVACY.md](../../PRIVACY.md).

## Synthetic browsing

For an explicitly authorized GUI run:

```bash
./Scripts/browse-synthetic.sh
```

For interactive browsing without the automated workload, use `./script/build_and_run.sh --demo`.
Both commands build an isolated Debug-only Spotty demo with the normal window, root view,
navigation, commands, and lifecycle.
It never launches or terminates the live Spotty app. The [version-1 scenario](../../Tests/BrowsingHarness/scenario.json)
defines two playlists, six [AI-generated covers](../../Tests/BrowsingHarness/Support/Artwork/prompts.json)
repeated across distinct artwork URLs, repeated visits, and a fixed viewing cadence. Pass a JSON
scenario path to change the bounded workload; `mode: "signed-out"` exercises the real signed-out
root view. Invalid scenarios fail closed. Playback, search, mutation, and recovery scenarios are
outside this first slice of [#41](https://github.com/aladh/Spotty/issues/41).

The demo injects all environment ports from one synthetic owner. Artwork loads from local fixture
files through `AsyncImage`. A separately signed app sandbox denies socket access, which
the workload verifies before browsing. No live auth, Keychain, engine, or audio-device dependency
is constructed. The demo uses the same Apple Development certificate selection as Spotty and the stable
`dev.spotty.demo` identity at `.build/Spotty Demo.app`, preserving macOS permissions across rebuilds.
Its blue [icon source](../../Tests/BrowsingHarness/Icon/SpottyDemo.icon) distinguishes it in the Dock.
Regenerate its fallback icon with `./Scripts/generate-icon.sh Tests/BrowsingHarness/Icon/SpottyDemo.icon/Assets/SpottyDemo.png Tests/BrowsingHarness/Icon/SpottyDemo.icns` after changing the source.
Its sandbox caches/preferences are separate from live Spotty and persist across launches. Each run
gets a new `.build/browsing-runs/` directory for fixtures and `report.json`. The app stays open for inspection.

The report records the scenario, commit/diff identity, machine/OS context, window size/scale,
checkpoint RSS and physical footprint, cumulative CPU time, store loading time, scroll positions,
catalog request counts, fixture size, and framework cache footprint. Repeat the same scenario on
the same machine/configuration and compare several runs; Debug timings and synthetic source bytes
do not measure live network latency or Release performance. First visits are cold-process samples, with potentially warm framework disk caches;
later cycles show reuse within that process. Framework scheduling and measured timings can vary.
A verified network sandbox, zero mutation attempts, and a completed report are acceptance checks, not performance budgets.

`check.sh` runs the harness's headless fixture, port, and read-only browsing checks. The normal
package graph excludes every harness target; the shipping product has no synthetic launch selector.
