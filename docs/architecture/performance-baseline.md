# Playback performance baseline

[Engine ownership](playback-engine-ownership.md)

## Historical measured baseline (2026-08-23)

This predates the retained-engine cleanup. It is historical context, not a current performance
claim or migration gate. Any new comparison must record its commit and product surfaces.

Spotty 0.4.0 (4), optimized signed Release bundle, macOS 27.0 (26A5416b), Apple M1 Max, 32 GB.
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

Reports: `run.1cZyJ9nU` at `ca93ce3` (before), `run.qEy750jC` at `ffab157` (after), both with
an empty tracked diff. They precede the final harness review corrections to exact cluster barriers,
recovery preservation and callback invocation counting. A second after run (`run.yi56SLpy`, same
presentation implementation before commit) counted the same semantic invalidations and measured
12.72 CPU seconds, showing timing variance. These are directional samples, not a statistical
performance guarantee. CPU includes all process threads, not specifically MainActor time.

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

Synthetic Demo playback scenario at `a526fb762a1d52c841a811615cee0f6c63480435`, clean worktree,
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
