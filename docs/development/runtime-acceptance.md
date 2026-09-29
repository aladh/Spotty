# Runtime architecture acceptance

[Verification](verification.md) · [Architecture decisions](../architecture/adrs/README.md)

Apply the [product contracts](../product/README.md) as well as
[PR acceptance](../../CONTRIBUTING.md#pr-acceptance).

## Evidence for the implemented scope

Follow the relevant [ADR](../architecture/adrs/README.md) and [verification gate](verification.md#normal-verification).
Independently verify admission, account/engine replacement, cancellation, retirement during I/O,
late publications, and corrupt retained data. Stored identities never authorize fresh mutations.
For catalog changes, include route restoration, write invalidation, shared enrichment, and artwork
retirement under [ADR 009](../architecture/adrs/ADR-009-account-catalog-retention.md#decision).

For UI changes, follow the [visual fidelity contract](../product/scope.md#visual-fidelity-and-interaction)
using synthetic fixtures. Tests cannot establish visual parity or grant
[live-account permissions](../product/safe-testing.md).

## Production process

Verify runtime admission, account/engine identity, and settlement: expiration differs from
confirmation; late observations still update playback truth.
[PRIVACY.md](../../PRIVACY.md#local-storage) owns OAuth storage. A future Keychain migration needs
recoverable grant migration and evidence for updates, developer builds, lock/unlock, and reinstall;
old Keychain entries remain untouched.

### Quit and playback position

With playback-test permission, record the paused position, destination's prior open state,
and fresh Connect observations after quit. Shutdown cannot prove Spotify's
restored position: closed apps restore their
[cached sessions](https://community.spotify.com/t5/Other-Podcasts-Partners-etc/Sync-player-progress-between-devices/m-p/5515721/redirect_from_archived_page/true).
An open Spotify can observe the position before disconnection. Never retain a phantom device or
modify Spotify's files to bypass caching. Quit stops the runtime; window closure does not.

## Measurements

Record source/engine identities, system, display, window state, and workload. Compare matched
optimized builds without concurrent compilation or UI inspection.

```bash
./Scripts/browse-synthetic.sh --optimized Tests/BrowsingHarness/queue-rendering.json
./Scripts/browse-synthetic.sh Tests/BrowsingHarness/measurement.json
```

`--optimized` uses instrumented, testable Release code with synthetic dependencies. `report.json`
records CPU/memory, hydration, and publications. Callback gaps measure display opportunities, not
presentation or input-to-pixel latency. Subtract first from last cumulative CPU counters to exclude
startup. Occluded runs cannot measure rendered-frame budgets. Cold-process visits may use filesystem
caches; later cycles measure reuse. The workload suppresses App Nap while allowing idle sleep.

Queue-rendering uses `forceSynchronousLayout: false` for normal AppKit scheduling; omission retains
synchronous stress. Compare identical modes. A verified sandbox, zero unexpected mutations, and
completed workload establish functional acceptance, not speed.

Opt-in probes:

| Output variable | Filter | Measurement |
| --- | --- | --- |
| `SPOTTY_CATALOG_MEASUREMENT_REPORT` | `CatalogMetadataMeasurementTests` | Catalog publication CPU |
| `SPOTTY_CATALOG_PREPARATION_REPORT` | `CatalogPreparationMeasurementTests` | Preparation CPU and peak RSS |
| `SPOTTY_PATHFINDER_DECODING_REPORT` | `PathfinderDecodingMeasurementTests` | Gateway decoding CPU and peak RSS |
| `SPOTTY_METADATA_EXCHANGE_REPORT` | `CatalogMetadataExchangeMeasurementTests` | Metadata exchange CPU and admission latency |
| `SPOTTY_TRACK_SORT_REPORT` | `measureTrackTableSorting` | Track sorting CPU |
| `SPOTTY_TRACK_ENRICHMENT_REPORT` | `measureTrackCollectionEnrichment` | Collection enrichment CPU |
| `SPOTTY_NATIVE_TRACK_UPDATE_REPORT` | `NativeTrackUpdateMeasurementTests` | Offscreen table-update CPU |
| `SPOTTY_ENTITY_OBSERVATION_REPORT` | `measureUnchangedEntitySubscriptions` | Subscription admission CPU |
| `SPOTTY_ENTITY_PAGING_REPORT` | `CatalogEntityPagingMeasurementTests` | Bounded storage paging CPU |
| `SPOTTY_ARTWORK_DECODE_REPORT` | `ArtworkDecoderMeasurementTests` | Decoder CPU and asset bytes |
| `SPOTTY_ARTWORK_MEASUREMENT_REPORT` | `ArtworkSourceLoaderMeasurementTests` | Idle loader process footprint |

```bash
SPOTTY_CATALOG_MEASUREMENT_REPORT=/tmp/catalog.json python3 Scripts/verify.py test --test-product SpottyBoundaryTests \
  -c release --scratch-path .build/browsing-optimized -Xswiftc -O -Xswiftc -enable-testing \
  -Xswiftc -DSPOTTY_BROWSING_OPTIMIZED --filter CatalogMetadataMeasurementTests
```

Track probes use `verify.py domain -c release --filter FILTER`. Gateway probes use
`verify.py test --test-product SpottyGatewayTests -c release -Xswiftc -O -Xswiftc -enable-testing --filter FILTER`.
Repeat matched runs with `--skip-build`. Results are samples, not thresholds or whole-app claims.

### Visible Instruments captures

Add `--profile` for Xcode's Animation Hitches template. Read-only preflight checks Xcode/SDK,
recorder/template, console session, and lock/display state before building.
It never unlocks the session or requests grants. Unknown session state fails closed; an absent lock
flag in an active logged-in session is labeled an inference.

Keep the window unoccluded. `--profile --interactive` lets you prepare the inspector before choosing
**Demo → Run Measurement**. The workload waits for the exact-PID recorder handshake and refreshed
session/window/process admission. Unusable tracing grants fail before measurement starts.

The [manifest](../../Scripts/browsing_provenance.py), [process record](../../Scripts/browsing_process.py),
and [readiness report](../../Tests/BrowsingHarness/Support/BrowsingRunStatus.swift) bind source/build,
process, and window/display evidence. Source identity includes
untracked inputs, and readiness excludes account/catalog content.

Wait for `profiler-state.json` to reach `complete` or `failed`; a passing workload report precedes
trace saving and cannot establish capture completion. The workload deadline is 600 seconds, with
another 180 for saving. Completion requires a matching successful workload, saved trace, required
exports, and complete application frames. Malformed or interrupted runs fail closed with stable
reason codes. [Synthetic acceptance](synthetic-acceptance.md#evidence-and-review) explains early-failure artifacts.

The launcher writes `trace-summary.json`; the [summarizer](../../Scripts/summarize_synthetic_trace.py)
filters exports to the Demo workload/process. Pipelined frame lifetime is not a one-refresh deadline. Raw traces can contain
host information; keep them local and publish reviewed aggregates.

Compare completed captures:

```bash
python3 Scripts/compare_synthetic_profiles.py RUN_A RUN_B
```

Comparison commands report:

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

Compare two layouts from identical source:

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
SPOTTY_SWIFT_LIFECYCLE_REPORT=/tmp/spotty-swift-drain.json \
  python3 Scripts/verify.py test --test-product=SpottySessionRuntimeTests --filter PlaybackEffectDrainTests
```

These credential-free probes measure synthetic recovery and task drains without Spotify or audio.
Paused-time checks and injected construction do not measure network readiness; parked shutdown
constructs no Spirc/Dealer. Swift probes retain production grace periods and release/join fenced work.
