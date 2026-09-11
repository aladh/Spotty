# Build and verification

[Agent operations](../../CONTRIBUTING.md) · Run commands from the repository root.

## Build and run

For an authorized launch, from the repository root:

```bash
./script/build_and_run.sh
```

This verifies, builds, signs, and replaces the running app; do not use it as a compile check.
Modes include the default `run`, `--debug` (launches under `lldb`), `--logs`, `--telemetry`,
`--verify`, `--release`, and `--verify-release`.
See [launch constraints](../../script/AGENTS.md) and
[signing setup](signing.md) before authenticated launches.

## Normal verification

For UI changes, follow the [visual fidelity procedure](../product/scope.md#visual-fidelity-and-interaction).
Standing permissions cover [Spotty Demo](../product/safe-testing.md#spotty-demo-standing-authorization)
and [read-only Spotify comparison](../product/safe-testing.md#spotify-read-only-reference).

Use the smallest focused check per [AGENTS.md](../../AGENTS.md#development). Available gate scopes:

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
The Swift scope and packaging use the pinned binary without the Rust compiler. Verification also
requires Ruby (for parsed workflow invariants) and pinned cbindgen (for source header reproducibility);
packaging does not. A differing source input digest produces a pin-freshness warning without
implicitly rebuilding or replacing the independently released engine. Checks do not sign in or
initiate playback. See the [enforcement inventory](../architecture/enforcement.md) for coverage.

CI uses one macOS job for conditional Rust verification/candidate production, then Swift Debug
checks and the Release distribution compile. Debug and Release share one SwiftPM cache under a
combined key; separate configuration directories remain inside `.build`. CI restores source timestamps
only when tracked compiler input contents match the manifest saved with that build cache; changed and
new inputs keep checkout timestamps. Rust verification disables incremental products and keeps line-table
debug information to reduce cache transfer without changing assertions or test coverage. Release
caches include Cargo host tools as well as target products and a content-checked input timestamp manifest. Rust compiler tools are blocked
before Swift runs. A separate `Linux domain` job builds `SpottyDomain` and runs `SpottyDomainTests`
in a Swift container; `Package.swift` declares only those two targets off macOS, so an AppKit,
SwiftUI, AVFoundation, or playback-FFI import in the domain fails to compile there. Main requires
`Source policies`, `Linux domain`, and `macOS checks`. The final macOS step validates each phase
outcome, including the explicit decision required to skip Rust.

CI skips macOS for PRs limited to documentation, including nested `AGENTS.md` files. The Linux
source-policy and domain jobs still run; neither is conditional. Other PRs skip Rust only when limited to app sources/tests, assets, packaging, package pins, or
documentation. Engine, shared-header, CI, script, license, and unknown paths require Rust; main always
runs it. The Linux source-policy job uses the PR base commit's classifier. A base without the policy
requires Rust; a base without macOS classification keeps macOS enabled. Detection errors fail CI. Skipped Rust steps are accepted only after an
explicit successful app-only decision. Pinned cbindgen binaries are cached by version and runner image/architecture,
with a version check before reuse. Header regeneration and the Python playback checks also run on
app-only PRs. cbindgen parses source files directly without Cargo metadata; it remains available after
CI blocks the Rust compiler tools. See [CI policy](../../Scripts/ci_rust_policy.py) for exact paths.

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

Tests live in `Tests/SpottyDomainTests/` and `Tests/SpottyBoundaryTests/` (ordinary SwiftPM test
targets) and `Tests/BrowsingHarness/Checks` (the `SpottyBrowsingHarnessTests` target, which
`Package.swift` includes only when `SPOTTY_BUILD_BROWSING_HARNESS=1` is set; `check.sh` sets it).
`Tests/ABI`, `Tests/Compiler`, and `Tests/SourcePolicy` hold fixtures read by scripts rather than
test targets. Discover test names with `swift test list` (add `SPOTTY_BUILD_BROWSING_HARNESS=1` to
include the harness target), then filter for focused iteration:

```bash
swift test --disable-sandbox --filter ProtobufTests/testProtobuf
swift test --disable-sandbox --no-parallel --filter AuthFlowTests/testAuthFlow
```

Use `SPOTTY_CHECK_REPEATS=N ./Scripts/check.sh` with `N` from 1 through 25 when concurrency or
lifetime work merits stress. Main runs three passes. Boundary synchronization failures report their
call sites; injected clocks drive scheduling while elapsed-time limits serve only as hang watchdogs.

## Clean and risk-specific verification

For clean-build changes or diagnosis requiring a rebuild:

```bash
./Scripts/check-clean.sh
```

It runs the full scope (source policies included) against both Debug and Release, so it needs
the [engine toolchain](setup.md#engine-development), cbindgen, ast-grep, and Python 3.

This removes generated Swift build products, rebuilds the engine artifact, and verifies Debug and
Release. Preserve unrelated work. Use `./Scripts/compile-release-spotty.sh` for compile-only Release
verification.

## Diagnostics

Release builds use Unified Logging. `./Scripts/export-diagnostics.sh [lookback]` writes a bounded
report under ignored `diagnostics/`, defaulting `lookback` to `15m`; it never prunes that directory.
Handle reports according to [PRIVACY.md](../../PRIVACY.md).

## Synthetic browsing

Run the isolated demo under its [standing authorization](../product/safe-testing.md#spotty-demo-standing-authorization):

```bash
./Scripts/browse-synthetic.sh
```

For interactive browsing without the automated workload, use `./script/build_and_run.sh --demo`.
Its default [Demo scenario](../../Tests/BrowsingHarness/demo.json) has 28 playlists: 20 top-level
rows and two folders containing four playlists each, so the sidebar scrolls. Explicit scenario
paths and profiling retain their declared fixture size.
Both commands build an isolated Debug-only Spotty demo with the normal window, root view,
navigation, commands, and lifecycle.
It never launches or terminates the live Spotty app. The [version-1 scenario](../../Tests/BrowsingHarness/scenario.json)
defines two playlists, six [AI-generated covers](../../Tests/BrowsingHarness/Support/Artwork/prompts.json)
repeated across distinct artwork URLs, repeated visits, and a fixed viewing cadence. Pass a JSON
scenario path to change the bounded workload; `mode: "signed-out"` exercises the real signed-out
root view. Invalid scenarios fail closed. The version-2 playback scenario below extends this foundation; search and playlist mutation remain outside its scope.

The demo injects all environment ports from one synthetic owner. Artwork loads from local fixture
files through `AsyncImage`. A separately signed app sandbox denies socket access, which
the workload verifies before browsing. No live auth, Keychain, engine, or audio-device dependency
is constructed. The demo uses the same Apple Development certificate selection as Spotty and the stable
`dev.spotty.demo` identity at `.build/Spotty Demo.app`, preserving macOS permissions across rebuilds.
Its blue [icon source](../../Tests/BrowsingHarness/Icon/SpottyDemo.icon) distinguishes it in the Dock.
Regenerate its fallback icon with `./Scripts/generate-icon.sh Tests/BrowsingHarness/Icon/SpottyDemo.icon/Assets/SpottyDemo.png Tests/BrowsingHarness/Icon/SpottyDemo.icns` after changing the source.
Its sandbox caches/preferences are separate from live Spotty and persist across launches. Each run
gets a new `.build/browsing-runs/` directory for fixtures and `report.json`. The automated command waits for the report and fails if the workload fails or times out;
the app stays open for inspection.

The report records the scenario, commit/diff identity, machine/OS context, window size/scale,
checkpoint RSS and physical footprint, cumulative CPU time, store loading time, scroll positions,
catalog request counts, fixture size, and demo-container cache footprint. Repeat the same scenario on
the same machine/configuration and compare several runs; Debug timings and synthetic source bytes
do not measure live network latency or Release performance. First visits are cold-process samples, with potentially warm framework disk caches;
later cycles show reuse within that process. Framework scheduling and measured timings can vary.
A verified network sandbox, zero mutation attempts, and a completed report are acceptance checks, not performance budgets.

`check.sh` runs the harness's headless fixture, port, and read-only browsing checks. The normal
package graph excludes every harness target; the shipping product has no synthetic launch selector.

### Synthetic playback and fault traces

Run `./Scripts/browse-synthetic.sh Tests/BrowsingHarness/playback.json` for real controls and store
intake backed by one synthetic playback authority. Add `--interactive` before the scenario path to
browse freely. The Demo menu injects rejection, holds/releases observations, changes the observed
owner, disconnects, and starts a replacement generation. Normal transport, seek, shuffle/repeat,
transfer and queue commands operate only on that synthetic authority; no audio is rendered.

The automated workload checks play/pause, seek acceptance and rollback, old observations crossing a
handoff, disconnect/recovery, and logout/account replacement before browsing under 5 Hz playback
samples. `report.json` includes named command/observation settlement durations, playback counters,
observer invalidations, and main-run-loop display callback gap percentiles. Gaps are display
opportunities, **not measured GPU frame presentation**; settlement durations are not proof of
input-to-pixel latency. Reports declare refresh rate, reduced-motion state and hardware context.
Compare repeated runs on the same configuration without concurrent UI inspection or compilation.
The synthetic clock continues after the report so the completed Demo remains usable interactively.

The original version-1 browsing and signed-out scenarios remain read-only. All versions retain the
same OS network sandbox, injected environment ports, separate Demo identity and non-shipping graph.

### Combined hydration and lifecycle measurements

`Scripts/browse-synthetic.sh Tests/BrowsingHarness/measurement.json` adds six fresh 96-track
queue waves during playlist navigation/scrolling. The 5 Hz source runs independently of MainActor,
and each checkpoint records its cumulative emitted sample count. Synthetic metadata waits 15 ms per lookup;
production hydration retains its eight-request concurrency. Each wave reports ordering, first
metadata and complete hydration (5 ms polling resolution), plus diagnostic counter deltas. The
report also samples main-thread user + system CPU with Mach thread accounting on MainActor.
These are cumulative counters; subtract the first checkpoint from the last to exclude startup.
The finite workload suppresses App Nap while allowing idle system sleep, so slow variants do not
cross into a different background-throttling policy. Each hydration wave has a 30-second liveness
watchdog. The report declares window visibility; an occluded run can measure CPU and publications,
but cannot validate a rendered-frame budget.

Add `--profile` before the scenario path to attach the local Xcode Animation Hitches template.
The workload waits for the profiler before starting and requires an unoccluded window. Profiling
uses the ordinary 600-second report watchdog. The trace remains beside `report.json`;
inspect table availability before claiming rendered-frame statistics. A successful capture can
contain no supported presentation events. The recorder allows up to 180 seconds to save after
interruption; a failed or incomplete save is not valid evidence. Instruments adds overhead: compare profiled runs with
profiled runs and ordinary runs with ordinary runs. Raw traces may include host/process metadata;
keep them local and publish only reviewed aggregate measurements.

Use `--profile --interactive` to prepare a visible queue inspector before starting. Open the queue,
then choose **Demo > Run Measurement**; each process runs the workload once. The recorder still
owns a bounded wait for the report. `Demo workload` signposts delimit the measured interval, and
`Queue metadata batch` events record enrichment publication starts without track or account data.
The profile includes the `os_signpost` instrument so these boundaries can be exported. Filter frame
and hitch summaries to the workload interval and the Demo process; do not include preparation or
treat full pipelined frame lifetime as a one-display-interval deadline.

The engine's credential-free named fault measurement uses the production health cadence,
serialized reconnect seam, recovery lease and owned-child teardown:

```bash
SPOTTY_LIFECYCLE_REPORT=/tmp/spotty-lifecycle.json cargo test --locked \
  --manifest-path Backend/spotty-playback/Cargo.toml named_lifecycle_fault_measurements -- --ignored
SPOTTY_STALLED_SHUTDOWN_REPORT=/tmp/spotty-stalled-shutdown.json cargo test --locked \
  --manifest-path Backend/spotty-playback/Cargo.toml measure_stalled_spirc_task_deadline -- --ignored
SPOTTY_SWIFT_LIFECYCLE_REPORT=/tmp/spotty-swift-drain.json swift test --disable-sandbox \
  --no-parallel --filter PlaybackEffectDrainTests
```

The first measurement uses paused Tokio time for silent-fault detection and monotonic wall time for
30 recovery/drain samples. Its wall-clock loop is opt-in; the normal suite independently checks
the production cadence with explicit timer registration and paused time. Recovery injects 5 ms cleanup and 20 ms construction; its result
measures orchestration, not Spotify network connection or real session readiness. The ignored
measurement spends three real four-second deadlines on parked task shutdown; it creates no
actual Spirc/dealer. Swift records 12 cooperative and noncancelable drains with the production
250 ms grace period, then explicitly releases/joins each fenced operation. The normal suites
retain deterministic ownership, rollback, generation and cancellation checks. No measurement
constructs live credentials, opens a Spotify connection or renders audio.

For a matched publication control, apply
[`queue-unbatched.patch`](../../Tests/BrowsingHarness/Baselines/queue-unbatched.patch) to a disposable
checkout of the same revision and run the same scenario repeatedly. This changes only metadata
publication to one update per result; it preserves ownership, ordering, concurrency and metadata
delay. Reverse the patch before normal checks or delivery. Keep the inspector/display/window
configuration the same, do not compile or inspect UI during either workload, and retain actual
sample rates and source identity with the aggregate comparison.

To summarize a saved visible capture, export run 1's `os-signpost`, `hitches`, `hitches-updates`
and `hitches-frame-lifetimes` tables with `xcrun xctrace export --input TRACE --xpath
'/trace-toc/run[@number="1"]/data/table[@schema="SCHEMA"]' --output FILE`.
Name the XML files `PREFIX-signposts.xml`, `PREFIX-hitches.xml`,
`PREFIX-hitches-updates.xml` and `PREFIX-hitches-frame-lifetimes.xml`, then run
`python3 Scripts/summarize_synthetic_trace.py PREFIX`. A missing/incomplete workload marker or
missing app frames is an error. The output includes complete-frame counts, Instruments hitch
incidence, descriptive duration quantiles and half-open rolling-second batch counts. Inspect the
report's window visibility, motion setting and functional result separately before accepting a run.

The [queue rendering scenario](../../Tests/BrowsingHarness/queue-rendering.json) sets
`forceSynchronousLayout` to false to let AppKit schedule layout/display. The harness retains an
attached playlist scroll view across virtualization and reacquires it when SwiftUI replaces it.
Omitting the flag retains historical synchronous stress behavior; compare only identical modes.
