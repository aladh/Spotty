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
