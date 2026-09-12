# Playback performance baseline

[Engine ownership](playback-engine-ownership.md)

## Current status

The 2026-09-10 measurements below were taken when `Package.swift` pinned `playback-v0.1.4`.
They do not measure the headless runtime, persistent catalog, or direct AppKit dense surfaces.
The current engine selection is owned by [Package.swift](../../Package.swift); compare new results
using their recorded source and engine identities, not this historical pin. No current optimized
rendering or input-latency result is established by the records below.

## Historical measured baseline (2026-08-23)

This predates the retained-engine cleanup. It is historical context, not a current performance
claim or migration gate. Any new comparison must record its commit and product surfaces.

Spotty 0.4.0 (4), optimized signed Release bundle, macOS 27.0 (26A5416b), Apple M1 Max, 32 GB.
The "0.4.0 (4)" string is the pre-reset version from the initial commit `6c5c7cc`
(`CFBundleShortVersionString`/`CFBundleVersion` in `Packaging/Info.plist`) and predates v0.1.0.
Five `ps` samples at one-second intervals after the state stabilized; memory is RSS; foreground
and background are window open and closed in the same process.

| State | Window | Mean CPU | Mean RSS |
| --- | --- | ---: | ---: |
| Paused | Foreground | 0.0% | 256.20 MiB |
| Paused | Background | 0.0% | 254.83 MiB |
| Playing | Foreground | 28.58% | 262.65 MiB |
| Playing | Background | 20.80% | 262.39 MiB |

Renderer backpressure: of 1,971 one-millisecond playing observations, 1,935 were in the renderer's
deliberate producer sleep, with no allocator hotspot. Those measurements did not justify a Core
Media sample-buffer pool at the time; new optimization decisions need a current baseline.

## Synthetic playback and browsing comparison (2026-09-10)

Debug Spotty Demo, macOS 27.0 (26A5425a), 10 logical processors, 32 GiB, 960 × 692 window,
2× scale, 120 Hz display, reduced motion off. The isolated `playback.json` scenario uses 1,000
tracks, 48 artwork fixtures, three browsing cycles, and concurrent 5 Hz playback samples. Both
runs passed 40 browsing checkpoints and seven playback/lifetime traces, with network isolation
verified. No UI automation ran concurrently with either measurement.

| Measure | Before projections | After projections |
| --- | ---: | ---: |
| Now-playing observer invalidations | 99 | 40 |
| Device observer invalidations | 90 | 13 |
| Queue observer invalidations | 90 | 2 |
| Catalog-indicator invalidations | 5 | 5 |
| Main-run-loop callback gap p95 | 90.2 ms | 62.2 ms |
| Main-run-loop callback gap p99 | 197.9 ms | 146.4 ms |
| Maximum callback gap | 648.7 ms | 658.8 ms |
| Browsing elapsed time | 15.45 s | 15.69 s |
| Process CPU consumed during browsing | 16.20 s | 14.15 s |

Both runs were taken on the branch squashed as `ef77361` (#385) with an empty tracked diff. Their
reports were written to the untracked `.build/browsing-runs/` directory and were not archived under
`docs/architecture/measurements/`, so these rows are unarchived historical observations. They
precede the final harness review corrections to exact cluster barriers, recovery preservation and
callback invocation counting. A second after run with the same presentation implementation counted
the same semantic invalidations and measured 12.72 CPU seconds, showing timing variance. These are
directional samples, not a statistical performance guarantee. CPU includes all process threads, not
specifically MainActor time.

The display link measures main-run-loop opportunities, not rendered frames. The proposed frame
budget is still missed; no input-to-pixel measurement is claimed. Seven named synthetic settlements
ranged from 8.25 to 81.06 ms after the change; disconnect-to-ready was 16.98 ms through the synthetic
ports, not a Rust/Spotify network reconnection. Remaining now-playing invalidations include catalog
metadata enrichment. A deterministic boundary test separately verifies that 100 timing-only
publications invalidate neither semantic, device nor queue readers.

Reproduce with `Scripts/browse-synthetic.sh Tests/BrowsingHarness/playback.json`. The script prints
the fresh report path; see [verification](../development/verification.md) for
isolation and report limitations. This Debug workload does not replace the historical live Release
playback measurement above.

## Binary size

CI reports release sizes for comparison, not as a pass/fail budget. Read the run summary with
`gh run view <run-id>` or download the report with `gh run download <run-id> -n size-report`.
[report-size.sh](../../Scripts/report-size.sh) owns the measurements; retention is configured in
[CI](../../.github/workflows/ci.yml).

## Command outcome trace (2026-09-10)

Synthetic Demo playback scenario at `b3f474f1c9a32e5f4470882552563c7ace3cc995` (#387), clean worktree,
macOS 27.0 (26A5425a), run `Lb6EK3WN`. All 40 browsing checkpoints and seven playback traces passed.
[PlaybackTrace](../../Tests/BrowsingHarness/Support/PlaybackTrace.swift) separates synchronous
optimistic-state feedback from the permit claim and the timestamp of the accepted matching engine
observation. Feedback is the action-call duration; dispatch and observation are milliseconds from
reducer admission. The original report names its feedback field `admissionToFeedbackMilliseconds`;
the harness now names that field `actionToStateFeedbackMilliseconds` to reflect its measurement.
Observation receipt is not UI paint or
remote-service latency; the synthetic engine publishes immediately after applying its operation.

| Intent | Immediate state feedback | Dispatch | Matching observation |
| --- | ---: | ---: | ---: |
| Play | 1.491 | 34.901 | 34.955 |
| Pause | 0.305 | 7.397 | 7.409 |
| Seek | 0.186 | 5.203 | 5.213 |

The rejected seek settled in 4.679 ms; synthetic reconnect reached its checkpoint in 20.324 ms.
The display callback count was zero, so this run cannot establish frame smoothness or a frame budget.
These are single-run measurements, not percentile estimates. Repeat the scenario with
`Scripts/browse-synthetic.sh Tests/BrowsingHarness/playback.json`; its report retains the source
revision, diff digest, checkpoints, and measurement fields.

## Queue hydration and lifecycle acceptance (2026-09-10)

The [reviewed measurements](measurements/2026-09-10-acceptance.json) retain every completed wave,
per-run counters, source digests and lifecycle samples. Both queue variants were measured with
the `e15404a` (#390) harness and queue revision correction, on top of `9c7334a`. The
[control patch](../../Tests/BrowsingHarness/Baselines/queue-unbatched.patch) changes only metadata
publication to one update per result; it is a benchmark fixture, not a shipped mode.

Three runs per variant completed 40 browsing checkpoints, eight playback/lifetime traces and six
96-track hydration waves. Configuration: M1 Max, 10 logical processors, 32 GiB, macOS 27.0
(26A5425a), Xcode 27.0 (27A5252f), macOS 26.5 SDK, Debug, 960 × 692 window, inspector closed.
Each fresh process uses new artwork paths; framework disk caches may be warm. The source emits
on independent 200 ms deadlines: measured offered rates were 4.97–5.00 Hz. Synthetic metadata
waits 15 ms per lookup with production concurrency of eight. App Nap is suppressed for the finite
workload while idle system sleep remains allowed. No build or UI inspection ran during these six
measurements; network denial and zero forbidden mutation attempts passed in every run.

Rerun the current scenario with `Scripts/browse-synthetic.sh Tests/BrowsingHarness/measurement.json`.
This exercises today's checkout and engine pin, not the recorded commits, pin, or control patch, so
it does not reproduce the figures above.

The session exposed a 60 Hz Screen Sharing Virtual Display at 2× scale. All measured windows were
occluded at start and end and recorded zero display callbacks. These are useful publication,
CPU and hydration measurements, **not rendered-frame or input-to-visible-feedback evidence**.
The subsequent reduced-motion inspection was blocked by the locked Mac; its setting remained off.
No physical 120 Hz display was exposed. #379 remains open; #380 closed on 2026-09-10 and moved its
render-budget portion to #379.

Per-run medians, with ranges in parentheses:

| Measure | Per-result control | 50 ms batching |
| --- | ---: | ---: |
| Queue publications across six waves | 588 (588–588) | 35 (35–36) |
| Browsing workload elapsed | 59.53 s (58.60–60.80) | 15.49 s (15.48–15.62) |
| Main-thread CPU | 58.45 s (57.43–59.77) | 10.84 s (10.81–10.95) |
| Total process CPU | 64.54 s (63.53–65.76) | 16.19 s (15.94–16.29) |
| Peak physical footprint | 184.2 MiB (159.9–203.2) | 173.3 MiB (156.2–181.0) |
| Now-playing observer invalidations | 640 (639–640) | 80 (80–84) |
| Queue observer invalidations | 8 (8–8) | 8 (8–8) |

Batching reduced publication count by about 94% and main-thread CPU for the completed workload
by about 81%. The slower control receives more periodic samples because it runs longer; total
CPU includes that additional time. The footprint ranges overlap, so no reliable memory reduction
is established by these samples.

Across 18 waves per variant, state-observation p95 values were:

| Measure | Per-result control | 50 ms batching |
| --- | ---: | ---: |
| Authoritative order accepted | 80.9 ms | 73.6 ms |
| First metadata observed | 408.6 ms | 433.8 ms |
| All 96 metadata records observed | 9,736.8 ms | 1,019.3 ms |

Each wave fetched exactly 96 records in one flight, with one joining consumer and no wave
cancellation. Publication counts include the initial and terminal snapshots. The 5 ms polling
resolution and actor scheduling affect observed latency. The p95 values use the lower order
statistic at `floor((n - 1) × 0.95)`; these small samples describe this workload, not population
percentiles. The proposed 20-enrichment-publications/second ceiling still needs validation against
visible rendering. First metadata was not faster in this workload, despite much earlier completion.

The initial control exposed a correctness bug: metadata could advance the presentation revision
past a later accepted Connect wire revision. Reusing that presentation revision then caused the
store to reject fresh ordering. The regression reproduced the collision at revision 2; accepted
Connect updates now advance the separate presentation counter while preserving the wire revision
used by mutation validation. Both final variants include that fix. Earlier calibration runs with
an actor-bound source, background throttling or failed watchdogs are excluded from the comparison.

### Named lifecycle seams

The same artifact records credential-free tests of the production cadence, recovery lease,
serialized cleanup/build seam, owned-child teardown and Swift effect drain. No actual AP session,
Spirc/dealer connection or audio device is constructed. The
[verification guide](../development/verification.md#combined-hydration-and-lifecycle-measurements)
owns the commands and exact injected costs.

| Named fault | Observed result | Initial seam budget |
| --- | --- | --- |
| Silent invalid session at 0, 17 and 59.5 seconds into the cadence | 60,000 / 43,000 / 500 ms on paused Tokio time | Next 60-second policy check; no wall/network latency claim |
| Overlapping recovery claim; injected 5 ms cleanup + 20 ms build | 30 wall-clock samples; p95 29.53 ms, max 30.97 ms | p95 <50 ms for this injected workload |
| Five parked cancellable engine children | 30 samples; p95 0.161 ms, max 0.192 ms; all joined | p95 <10 ms |
| Parked Spirc-task seam ignores shutdown | Three samples; max 4,002.97 ms; abort and join completed | Existing 4-second deadline +100 ms scheduling margin |
| Cooperative Swift account effect | 12 samples; p95 0.549 ms, max 0.636 ms | p95 <10 ms |
| Noncancelable Swift effect | 12 samples; p95 266.51 ms, max 266.67 ms; fenced, then explicitly released/joined | Existing 250 ms grace +50 ms scheduling margin |

The overhead budgets leave scheduling margin around the named injected work and existing drain
policies; they are diagnostic targets, not timing assertions in the normal test suite. The silent
case verifies cadence rather than changing polling policy. The parked-task deadline does not
include the separate bounded dealer-close path of a real session.

**#378 remains open:** these measurements establish orchestration and drain behavior, but an
injected construction delay is not actual Rust engine construction/rehydration-to-ready latency.
That remaining measurement must cover the real readiness path under named faults before closing
the original acceptance item. These data do not establish a Spotify reconnection budget.

### Visible 120 Hz follow-up (2026-09-10)

After the display configuration changed, the built-in Liquid Retina XDR was available at
3456 × 2234 physical pixels, 1728 × 1117 points, 2× scale and nominal 120 Hz. The
[visible samples](measurements/2026-09-10-visible-acceptance.json) replace the earlier display
blocker with measured evidence; they do not replace the matched, unprofiled batching comparison.

The measured code/fixture contents are committed at `c924756` (#391); later flag-order, non-playback
menu-separator and JSON-label cleanups do not alter this playback workload. Two final marked
captures used the same Debug combined workload and 960 × 692 window with the
queue inspector open throughout: one with Reduce Motion off, one on. Each passed 40 browsing
checkpoints, eight playback/lifetime traces, six 96-track hydration waves, network denial and zero
forbidden mutation attempts. Both reported visible windows at start and end. Reduce Motion was
restored to its original off setting. No UI inspection, compilation or trace export ran during
either measured interval. Earlier exploratory captures are excluded from these results.

| Workload-only measure | Reduce Motion off | Reduce Motion on |
| --- | ---: | ---: |
| Signposted workload duration | 15.67 s | 15.82 s |
| Complete app frames | 729 | 781 |
| Frames with an Instruments-reported hitch | 110 (15.09%) | 125 (16.01%) |
| Reported hitch duration p95 / maximum | 300.00 / 441.66 ms | 316.67 / 458.33 ms |
| Full pipelined frame lifetime p95 | 118.24 ms | 114.47 ms |
| Main-thread CPU between first/last checkpoint | 11.13 s | 10.86 s |
| Emitted playback samples per second | 5.00 | 5.01 |
| Enrichment batch events | 20 | 19 |
| Maximum enrichment batches in a rolling second | 4 | 3 |
| Minimum spacing between enrichment batch events | 121.48 ms | 119.44 ms |

Rerun the current scenario with
`Scripts/browse-synthetic.sh --profile --interactive Tests/BrowsingHarness/measurement.json`, then
choose **Demo > Run Measurement** with the queue inspector open; this measures today's checkout,
not the recorded commits.
[Scripts/profile_synthetic.py](../../Scripts/profile_synthetic.py) is the recorder that
`browse-synthetic.sh` invokes to produce the trace; the
[summary helper](../../Scripts/summarize_synthetic_trace.py) resolves exported XML references,
selects the single `Demo workload` interval and joins frame display/swap IDs to this Demo process's
update records. It excludes frames crossing either workload boundary. Frame lifetime includes
multiple pipeline stages; it is **not** input-to-visible latency or a one-display-interval deadline.
Apple's [frame-lifetime explanation](https://developer.apple.com/documentation/xcode/understanding-hitches-in-your-app)
distinguishes the pipeline's acceptable latency from hitch duration. The reported hitch incidence
is already incompatible with claiming the proposed smoothness target satisfied. These are
single profiled runs on a beta OS/toolchain, not a statistically established effect of Reduce Motion.
The [workload](../../Tests/BrowsingHarness/Support/BrowsingApplication.swift) makes large programmatic
scroll jumps and forces synchronous layout/display at checkpoints and view readiness. The CPU
trace includes substantial work under those harness calls. These stress results cannot identify
ordinary-input latency or attribute the hitches solely to production invalidation; profile native
input and separate harness-forced layout costs before choosing a rendering fix.

The proposed 20-enrichment-publications/second ceiling passed these visible workload samples.
This does not establish that a 50 ms batching policy is sufficient for the overall rendering budget:
substantial hitches remain while publication frequency is low. #380 closed on 2026-09-10 and moved
that budget acceptance to #379; the missing evidence is now a satisfactory rendering result, not an
unavailable display. #379 still needs control-input-to-visible-feedback measurement and work to
meet or explicitly revise its rendering target. State observation, display-link callbacks and
accessibility automation do not substitute for that control measurement. #378's real Rust
construction/rehydration-to-ready fault timing remains unchanged by this Demo follow-up.

### AppKit-scheduled queue rendering (2026-09-10)

The [follow-up samples](measurements/2026-09-10-queue-rendering.json) use source `88c099c`,
with the existing per-result control patch applied only to the control checkout. That JSON's
`sourceRevision` field is the pre-squash branch commit; the actual squash commit on main is
`70b3bac` (#392). The
[scenario](../../Tests/BrowsingHarness/queue-rendering.json) keeps the prior combined workload
and open queue inspector, but lets AppKit schedule layout/display instead of forcing it from
readiness/checkpoint calls. Each variant completed 40 checkpoints, eight playback traces and
six 96-track hydration waves, with visible windows, Reduce Motion off, denied networking and
zero forbidden mutations. No compilation, UI inspection or export ran during either workload.

Rerun the current scenario with
`Scripts/browse-synthetic.sh --profile --interactive Tests/BrowsingHarness/queue-rendering.json`,
then choose **Demo > Run Measurement**; this measures today's checkout, not the recorded commits or
control patch.

| Measure | Batched | Per result |
| --- | ---: | ---: |
| Signposted workload duration | 15.90 s | 62.48 s |
| Main-thread CPU between first/last checkpoint | 12.29 s | 61.17 s |
| Total queue publications, including lifecycle setup | 45 | 606 |
| Complete app frames | 188 | 252 |
| Frames with an Instruments-reported hitch | 117 (62.23%) | 152 (60.32%) |
| Full pipelined frame lifetime p95 | 197.21 ms | 209.53 ms |
| Reported hitch duration p95 | 325.00 ms | 191.67 ms |
| Observed display callback nominal rate | 120 Hz | 60 Hz |

This is one profiled sample per variant on the built-in ProMotion display and beta toolchain.
The reported callback rate differed despite unchanged display settings, so this is not a
fixed-refresh matched rendering experiment. Frame counts and hitch fractions describe each
run; neither a rendering improvement nor a regression is established. Batching again reduces
publication and CPU work, but both captures miss the proposed smoothness target. The batched
capture emits at most four metadata batch events in a rolling second; low publication frequency
alone does not satisfy the remaining rendering acceptance.

Removing explicit synchronous layout did not eliminate hitches. Programmatic scroll jumps,
Debug/profiling overhead and the broader UI remain possible contributors. These samples do not
measure physical control-input latency or isolate a production root cause. **#379 remains open** as
the sole rendering-budget owner after #380 closed on 2026-09-10; closing it requires a satisfactory
UI budget, not just this publication/CPU saving.
The richer interactive Demo library is a separate fixture and was not used in these captures.
