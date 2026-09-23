# Runtime architecture acceptance

[Verification](verification.md) · [Architecture decisions](../architecture/adrs/README.md)

Attach evidence to the reviewed revision and report missing measurements.
[PR acceptance](../../CONTRIBUTING.md#pr-acceptance) alone does not establish runtime, visual,
or performance goals in the [product contracts](../product/README.md).

## Implemented boundary

[ADR 008](../architecture/adrs/ADR-008-headless-session-runtime.md) owns the in-process session
executor and desktop observation boundary; [ADR 009](../architecture/adrs/ADR-009-account-catalog-retention.md)
owns verified-account catalog retention; [ADR 010](../architecture/adrs/ADR-010-native-dense-surfaces.md)
assigns dense scrolling and selection to AppKit. Offline startup remains unauthorized;
Spotify appearance remains a [product requirement](../product/scope.md).

## Evidence for the implemented scope

Use the complete gate for boundary changes, with independent expected behavior. Cover admission,
account/engine replacement, cancellation, retirement during I/O, late publications, and partial or
corrupt retained data at the changed owner. Stored identities never replace fresh mutation admission.

For catalog changes, exercise route restoration, write invalidation, shared enrichment, and artwork
retirement against [ADR 009's retention and ownership constraints](../architecture/adrs/ADR-009-account-catalog-retention.md#decision).

Inspect native states, inputs, and resized layouts under the
[visual fidelity contract](../product/scope.md#visual-fidelity-and-interaction), recording the
reference, deviations, and unperformed states. Tests do not establish visual parity. Use synthetic
data; [live-account permissions](../product/safe-testing.md) still apply.

## Production process

The runtime is in-process; a custom session XPC helper is not an acceptance gate. Verify stamped
admission, account/engine identity, and settlement: expiration differs from confirmation, and late
observations still update playback truth. [PRIVACY.md](../../PRIVACY.md#local-storage) owns OAuth storage.
A future Keychain migration needs recoverable grant migration and update, developer-build,
lock/unlock, and reinstall evidence; old Keychain entries remain untouched.

### Quit and playback position

With explicit playback-test permission, record the paused position, destination's prior open state,
and fresh Connect observations after quit and disconnection. Shutdown cannot prove Spotify's
restored position: closed apps restore their
[cached sessions](https://community.spotify.com/t5/Other-Podcasts-Partners-etc/Sync-player-progress-between-devices/m-p/5515721/redirect_from_archived_page/true).
An open Spotify can observe the position before disconnection. Never retain a phantom device or
modify Spotify's files to bypass caching. Quit stops the runtime; window closure does not.

## Scope boundaries

[Product scope](../product/scope.md) still governs expansion. Queue removal needs retained-engine
support; playlist administration, preferences, and multi-selection mutations require separate
scope and verification.

## Measurements

Record source/engine identities, scenario, system, display, window state, and workload. Repeat matched
configurations without concurrent compilation or UI inspection. Historical Debug samples are not an
optimized baseline; architecture and compilation establish no speedup.

```bash
./Scripts/browse-synthetic.sh --optimized Tests/BrowsingHarness/queue-rendering.json
./Scripts/browse-synthetic.sh Tests/BrowsingHarness/measurement.json
```

`--optimized` uses instrumented, testable Release code with synthetic dependencies. `report.json`
records CPU/memory, hydration, and publications. Callback gaps measure display opportunities, not
presentation or input-to-pixel latency. Subtract first from last cumulative CPU counters to exclude
startup. Occluded runs cannot measure rendered-frame budgets. Cold-process visits may use filesystem
caches; later cycles measure reuse. The workload suppresses App Nap while allowing idle sleep.
Fixtures own workload parameters.

Queue-rendering uses `forceSynchronousLayout: false` for normal AppKit scheduling; omission retains
synchronous stress. Compare identical modes. A verified sandbox, zero unexpected mutations, and
completed workload establish functional acceptance, not speed.

### Visible Instruments captures

Add `--profile` before the scenario for Xcode's Animation Hitches template. Before building,
read-only preflight checks Xcode/SDK, recorder/template, console session, and lock/display state.
It never unlocks the session or requests grants. Unknown session state fails closed; an absent lock
flag in an active logged-in session is labeled an inference.

Keep the window unoccluded. `--profile --interactive` lets you prepare the inspector before choosing
**Demo → Run Measurement**. The workload waits for the exact-PID recorder handshake and refreshed
session/window/process admission. Unusable tracing grants fail before measurement starts.

The [manifest](../../Scripts/browsing_provenance.py), [process record](../../Scripts/browsing_process.py),
and [readiness report](../../Tests/BrowsingHarness/Support/BrowsingRunStatus.swift) bind source/build,
process, and window/display evidence. Their owners define the fields; source identity includes
untracked inputs, and readiness excludes account/catalog content.

Wait for `profiler-state.json` to reach `complete` or `failed`; a passing workload report precedes
trace saving and cannot establish capture completion. The workload deadline is 600 seconds, with
another 180 for saving. Completion requires a matching successful workload, saved trace, required
exports, and complete application frames. Malformed or interrupted runs fail closed with stable
reason codes. [Synthetic acceptance](synthetic-acceptance.md#evidence-and-review) explains early-failure artifacts.

The launcher exports tables and writes `trace-summary.json`. The
[summarizer](../../Scripts/summarize_synthetic_trace.py) owns export inputs and filters to the Demo
workload/process. Pipelined frame lifetime is not a one-refresh deadline. Raw traces can contain
host information; keep them local and publish reviewed aggregates.

Compare completed captures:

```bash
python3 Scripts/compare_synthetic_profiles.py RUN_A RUN_B
```

The comparator and two-layout command below report:

| Exit | Classification | Meaning |
| --- | --- | --- |
| 0 | `comparable` | Valid captures with matching conditions. |
| 1 | `descriptive-only` | Valid captures with differing conditions or unknown inspector state. |
| 2 | `invalid` | Failed capture or missing/malformed evidence. |

`--allow-descriptive` on the comparator makes a descriptive result exit zero without accepting a
performance comparison. Inspector evidence comes from existing controls and native tables; an
unobserved inspector is not proof that it is closed. Maximum refresh is display capability;
observed target cadence is compared with a one-percent tolerance. Compare profiled runs only with
profiled runs.

Prepare, capture, and summarize an exact-source two-layout experiment:

```bash
python3 Scripts/profile_synthetic.py --compare-layouts Tests/BrowsingHarness/queue-rendering.json \
  --output .build/layout-comparison
```

Use a new output directory. The command prepares both fixtures before building, records sequentially,
closes each owned Demo, and writes `comparison.json`, including run directories on failure.
Only `forceSynchronousLayout` and its full fixture digest may differ; source, workload digest,
and other conditions must match. For existing variants, pass
`--variant-field layout.forceSynchronousLayout` to the comparator.

For a matched publication control, apply
[queue-unbatched.patch](../../Tests/BrowsingHarness/Baselines/queue-unbatched.patch) in a disposable
checkout of the same revision. It changes publication frequency while preserving hydration inputs
and ordering. Repeat the same scenario/configuration, record actual sample rates, and reverse the
patch before normal checks or delivery.

### Credential-free lifecycle measurements

```bash
SPOTTY_LIFECYCLE_REPORT=/tmp/spotty-lifecycle.json cargo test --locked \
  --manifest-path Backend/spotty-playback/Cargo.toml named_lifecycle_fault_measurements -- --ignored
SPOTTY_STALLED_SHUTDOWN_REPORT=/tmp/spotty-stalled-shutdown.json cargo test --locked \
  --manifest-path Backend/spotty-playback/Cargo.toml measure_stalled_spirc_task_deadline -- --ignored
SPOTTY_SWIFT_LIFECYCLE_REPORT=/tmp/spotty-swift-drain.json swift test --disable-sandbox \
  --no-parallel --filter PlaybackEffectDrainTests
```

These measure synthetic recovery and owned-task drains without Spotify connections, credentials,
or audio. Paused-time detector checks and injected construction delays do not measure network
readiness; parked-task shutdown measurements do not construct a real Spirc/Dealer. Swift drain
measurements use the production grace period and explicitly release/join fenced operations.
