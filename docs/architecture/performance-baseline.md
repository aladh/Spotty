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
observation. Times below are milliseconds from admission. Observation receipt is not UI paint or
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
