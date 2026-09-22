# Runtime architecture acceptance

[Verification](verification.md) · [Architecture decisions](../architecture/adrs/README.md)

Attach evidence to the reviewed revision and report missing measurements.
[PR acceptance](../../CONTRIBUTING.md#pr-acceptance) does not establish all architecture,
visual, or performance goals in [proposal #424](https://github.com/aladh/Spotty/issues/424).

## Implemented boundary

[ADR 008](../architecture/adrs/ADR-008-headless-session-runtime.md) defines the in-process session
executor and desktop observation boundary; [ADR 009](../architecture/adrs/ADR-009-account-catalog-retention.md)
defines verified-account catalog retention; [ADR 010](../architecture/adrs/ADR-010-native-dense-surfaces.md)
assigns dense scrolling and selection to AppKit. These changes neither authorize offline startup
nor establish faster rendering. Spotify appearance remains a [product requirement](../product/scope.md).

## Evidence for the implemented scope

Use the complete gate for boundary changes, with independent expected behavior. Cover admission,
account/engine replacement, cancellation, retirement during I/O, late publications, and partial or
corrupt retained data at the changed owner. Stored identities never replace fresh mutation admission.

Verify route restoration and invalidation after successful or uncertain writes. Shared enrichment
must preserve collection order, duplicates, selection, versions, freshness, and ownership without
another collection read. Artwork remains memory-only, with bounded fetching/decoding and retirement
checks. Detailed cases belong to the linked ADRs and executable tests.

Inspect native states, inputs, and resized layouts under the
[visual fidelity contract](../product/scope.md#visual-fidelity-and-interaction), recording the
reference, deviations, and unperformed states. Tests do not establish visual parity. Use synthetic
data and [safe testing](../product/safe-testing.md); architecture acceptance expands no live-account
permissions. Native ownership, fewer publications, and compilation alone establish no speedup.

## Production process

The runtime stays inside the app; a custom session XPC cutover is not an acceptance gate.
Verify stamped admission, account/engine identity, and intent settlement: expiration remains distinct
from observed confirmation, and late observations still update playback truth.
OAuth storage remains as specified in [PRIVACY.md](../../PRIVACY.md#local-storage). A future Keychain
migration needs recoverable grant migration plus update, developer-build, lock/unlock, and reinstall
evidence; old Keychain entries remain untouched.

### Quit and playback position

Under explicit playback-test permission, record the paused position, whether the destination was
open before quit, and fresh Connect observations after quit and disconnection. Successful shutdown
cannot prove what Spotify restores: closed apps restore their own
[cached sessions](https://community.spotify.com/t5/Other-Podcasts-Partners-etc/Sync-player-progress-between-devices/m-p/5515721/redirect_from_archived_page/true).
Opening Spotify before disconnection lets it observe the current position. Never retain a phantom
active device or modify Spotify's files to bypass caching. Quit stops the runtime; window closure
is separate.

## Product expansions outside this cutover

[Product scope](../product/scope.md) still governs expansion. Queue removal needs retained-engine
support; playlist administration, preferences, and multi-selection mutations require separate
scope and verification.

## Measurements

Record source/engine identities, scenario, system, display, window state, and workload. Compare repeated
identical configurations without concurrent compilation or UI inspection. Historical Debug samples
are not an optimized baseline.

```bash
./Scripts/browse-synthetic.sh --optimized Tests/BrowsingHarness/queue-rendering.json
./Scripts/browse-synthetic.sh Tests/BrowsingHarness/measurement.json
```

`--optimized` uses instrumented, testable Release code with synthetic dependencies. `report.json`
records CPU/memory, hydration, and publications. Callback gaps measure display opportunities, not
presentation or input-to-pixel latency. Subtract first from last cumulative CPU counters to exclude
startup. Occluded runs cannot measure rendered-frame budgets. Cold-process visits can benefit from
filesystem caches; later cycles measure reuse. The workload suppresses App Nap while allowing idle
sleep. Fixtures own sizes, delays, rates, and deadlines.

The queue-rendering scenario sets `forceSynchronousLayout: false` for normal AppKit scheduling;
omitting it retains historical synchronous stress. Compare identical modes. A passing sandbox,
zero unexpected mutations, and completed workload establish functional acceptance, not speed.

### Visible Instruments captures

Add `--profile` before the scenario for Xcode's Animation Hitches template. Read-only preflight
checks the selected Xcode/SDK, recorder/template, console session, and lock/display state before
building. It never unlocks the session or requests grants. Unavailable session evidence fails
closed; an absent lock flag in an active logged-in session is explicitly labeled an inference.

Keep the window unoccluded. `--profile --interactive` lets you prepare the inspector before choosing
**Demo → Run Measurement**. The workload waits for the exact-PID recorder handshake and refreshed
session/window/process admission. Unusable tracing grants fail before measurement starts.

[`manifest.json`](../../Scripts/browsing_provenance.py) retains run/source/fixture/build/engine/layout
identities, including untracked inputs. [`process.json`](../../Scripts/browsing_process.py) binds PID,
start, and executable; [`run-status.json`](../../Tests/BrowsingHarness/Support/BrowsingRunStatus.swift)
publishes bounded readiness/window/display state without account or catalog content. Each link owns
its field definitions.

Wait for `profiler-state.json` to reach complete/failed; workload completion precedes recorder saving.
The workload deadline is 600 seconds, with another 180 seconds allowed for save. Completion requires
a matching successful workload, saved trace, required exports, and complete application frames.
Failures carry stable reason codes; interrupted runs cannot retain an accepted summary.

The launcher exports the required tables and writes `trace-summary.json` automatically. The
[summarizer](../../Scripts/summarize_synthetic_trace.py) owns manual export inputs and filters to the
Demo workload/process. Pipelined frame lifetime is not a one-refresh deadline. Keep raw traces local
and publish reviewed aggregates; they can contain host information.

Compare completed captures:

```bash
python3 Scripts/compare_synthetic_profiles.py RUN_A RUN_B
```

The validator rejects incomplete/failed evidence. Incompatible conditions or unknown inspector state
are descriptive only; `--allow-descriptive` changes the exit status without accepting a performance
comparison. Inspector evidence uses existing controls and native tables. Display maximum refresh
is capability; observed target cadence, callback gaps, and frame presentation are separate evidence.
Target-cadence differences beyond one percent are explicit. Compare profiled runs only with profiled runs.

Prepare, capture, and summarize an exact-source two-layout experiment:

```bash
python3 Scripts/profile_synthetic.py --compare-layouts Tests/BrowsingHarness/queue-rendering.json \
  --output .build/layout-comparison
```

Use a new output directory. This prepares both fixtures before building, records sequentially,
closes each owned Demo, and writes `comparison.json`. Only `forceSynchronousLayout` and its full
fixture digest may differ; source, workload digest, and other conditions must match. Incompatible
or incomplete runs return nonzero. For existing variants, pass
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
