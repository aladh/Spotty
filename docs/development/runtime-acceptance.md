# Runtime architecture acceptance

[Verification](verification.md) · [Architecture decisions](../architecture/adrs/README.md)

A green PR satisfies [PR acceptance](../../CONTRIBUTING.md#pr-acceptance), not every architecture,
visual, or performance goal in [proposal #424](https://github.com/aladh/Spotty/issues/424).
Attach evidence to the reviewed revision and report missing measurements explicitly.

## Implemented boundary

[ADR 008](../architecture/adrs/ADR-008-headless-session-runtime.md) defines the in-process session
executor and desktop observation boundary; [ADR 009](../architecture/adrs/ADR-009-account-catalog-retention.md)
defines verified-account catalog retention; [ADR 010](../architecture/adrs/ADR-010-native-dense-surfaces.md)
assigns dense scrolling and selection to AppKit. These changes neither authorize offline startup
nor establish faster rendering. Spotify appearance remains a [product requirement](../product/scope.md).

## Evidence for the implemented scope

Use the complete gate for boundary changes, retaining independent expected behavior in tests.
Focus failure tests on the changed ownership boundary:

- Account replacement, cancellation, late publications, account/engine identity, stamped admission,
  retirement during I/O, corrupt/unsupported caches, purge failure, and complete versus partial collections.
  Stored owners and occurrence IDs cannot replace fresh mutation admission.
- Shared artwork fetching across size/tint requests, memory bounds, oversized-image rejection, and
  retirement during fetch/decode. Keep artwork memory-only; request/memory evidence is separate from rendering speed.
- A → B → A route restoration, stale content after read failure, and old-account/route rejection.
  Successful or uncertain admitted writes must invalidate retained routes too.
- Shared-track enrichment across active and retained playlists/albums without another collection
  read. Preserve duplicate IDs, UIDs, order, date added, selection, freshness, and ownership;
  unchanged collections keep their versions. Cover bounded/paged revisions, coalescing, missing
  entities, and retirement during reads. Partial or superseded results cannot update rows or
  become fresh mutation authority.
- Native surface states and input, including resized layouts, under the
  [visual fidelity contract](../product/scope.md#visual-fidelity-and-interaction).
  Record the reference, deliberate differences, and unperformed states. Behavior tests do not
  establish visual parity.

Use synthetic data and [safe testing](../product/safe-testing.md); architecture acceptance does
not expand live-account permissions. Never infer performance from native ownership, fewer
publications, or compilation alone.

## Production process

The runtime stays inside the app; a custom session XPC cutover is not an acceptance gate.
Verify stamped admission, account/engine identity, and intent settlement: expiration remains distinct
from observed confirmation, and late observations still update playback truth.
OAuth storage remains as specified in [PRIVACY.md](../../PRIVACY.md#local-storage). A future Keychain
migration needs recoverable grant migration plus update, developer-build, lock/unlock, and reinstall
evidence; old Keychain entries remain untouched.

## Product expansions outside this cutover

Local queue removal needs retained-engine protocol support. Broader playlist administration,
preferences, and multi-selection drag mutations require separate product scope and verification;
architecture work does not imply them. See [product scope](../product/scope.md).

## Measurements

Record source and engine identities, scenario, system, display refresh/scale, window size/visibility,
and workload. Compare repeated runs with identical configurations and no concurrent
compilation or UI inspection. Historical Debug samples are not an optimized baseline.

```bash
./Scripts/browse-synthetic.sh --optimized Tests/BrowsingHarness/queue-rendering.json
./Scripts/browse-synthetic.sh Tests/BrowsingHarness/measurement.json
```

`--optimized` uses instrumented, testable Release code with synthetic dependencies, not production
audio. `report.json` records CPU/memory, hydration, and publication evidence. Main-run-loop callback
gaps are display opportunities, not GPU presentation or input-to-pixel latency. Subtract first from
last cumulative CPU counters to exclude startup. Occluded runs can measure CPU/publications, not
rendered-frame budgets. Scenario sizes, delays, sample rates, and deadlines belong to the fixtures.
First visits are cold-process samples; later cycles measure reuse. Even first visits can benefit
from filesystem caching. The finite workload suppresses App Nap while allowing idle system sleep.

The queue-rendering scenario sets `forceSynchronousLayout: false` for normal AppKit scheduling;
omitting it retains historical synchronous stress. Compare identical modes. A passing sandbox,
zero unexpected mutations, and completed workload establish functional acceptance, not speed.

### Visible Instruments captures

Add `--profile` before the scenario to use Xcode's Animation Hitches template. Keep the window
unoccluded; the workload waits for profiling. `--profile --interactive` lets you open the queue
inspector before choosing **Demo → Run Measurement** (once per process).

The report deadline is 600 seconds; the recorder can take another 180 seconds to save after
interruption. Failed/incomplete saves are invalid evidence. A successful capture can still lack
presentation events. Compare profiled runs only with profiled runs. Raw traces can contain host
information; keep them local and publish reviewed aggregates.

Export run 1's `os-signpost`, `hitches`, `hitches-updates`, and `hitches-frame-lifetimes` tables:

```bash
xcrun xctrace export --input TRACE --xpath \
  '/trace-toc/run[@number="1"]/data/table[@schema="SCHEMA"]' --output FILE
python3 Scripts/summarize_synthetic_trace.py PREFIX
```

Name exports `PREFIX-signposts.xml`, `PREFIX-hitches.xml`, `PREFIX-hitches-updates.xml`, and
`PREFIX-hitches-frame-lifetimes.xml`. The summarizer rejects missing workload markers or app frames.
Filter to the Demo process and `Demo workload` interval. Do not treat full pipelined frame lifetime
as a one-refresh deadline. Check visibility and functional results separately.

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
