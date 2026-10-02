# Current Release playback measurements

[Runtime acceptance](runtime-acceptance.md) · [Performance baseline](../architecture/performance-baseline.md)
· [Safe testing](../product/safe-testing.md)

Historical app/engine and synthetic lifecycle records do not establish the current Release playback
baseline. This procedure requires explicit current-task authorization for its named live workload
and artifact admission under the safe testing and launch contracts. Preparation grants no playback,
account/device changes or live-app replacement permission.

Before a run, identify a clean source revision and exact optimized signed Release executable,
record its build flags and SHA256, verify consumed engine provenance and pin checksum, and record
OS version, processor class, memory, output device, window dimensions, display rate and scale.
Keep machine/account identifiers and media names out of public receipts. Record whether the app,
engine, catalog and audio paths are cold or warm; audio caching is disabled unless the recorded
artifact establishes otherwise. Never label a warm process or OS page cache as a cold startup.

Use a fixed, explicitly authorized bounded workload and the same output/device/window conditions
for each comparison. Use 60-second samples after 15 seconds of settling, three repetitions of paused/playing ×
window open/closed. Rotate the four-cell starting order across repetitions; retain the actual order.
Closing a window leaves the process running. A changed workload, output, app state or sampling
method excludes that interval rather than extending or silently repeating it. Record elapsed
wall time and CPU time deltas rather than comparing single instantaneous `%CPU` observations.
Record physical footprint separately from RSS. Capture process wakeup counter deltas with a
supported native profiler; report the profiler's counter definition and sampling overhead. A
resource snapshot does not establish output latency.

The current [renderer](../../Sources/SpottyEngineAdapter/AudioRenderer.swift) emits its metrics only
at stop: lifetime underrun count, dropped sample count, producer throttle seconds, and a single
buffered sample count (frames × channels). Preserve that summary with its actual stop boundary;
it includes settling and transitions and cannot establish individual 60-second interval deltas or
occupancy history. Mark those interval measurements unmeasured unless an admitted snapshot source
exists; do not insert extra stops merely to obtain counters. Separate intentional producer pacing
and explicit seek/stop discards from underruns. Native time profiling must attribute engine/decode/network,
UI/main thread and renderer work separately; whole-process CPU cannot perform that split.
Do not infer network bytes from cache-layer synthetic input counts.

Startup-to-ready needs an observed launch boundary and the actual readiness event for that signed
artifact. Play-to-output needs an authorized control boundary and an observed output boundary;
callback submission alone does not establish audible output. If either boundary is unavailable,
report it as unmeasured. Real recovery/construction timing remains owned by #378, live functional
acceptance by #431 and input/render timing by #379/#395; share compatible receipts without treating
one scope as completion of another.

Archive sanitized per-sample receipts and medians/ranges in the canonical performance baseline,
including failed or excluded runs and their reasons. Set a budget or open an optimization issue only when repeatable measurements identify a
user-visible cost. Keep raw captures local,
retire owned processes/windows and restore the original desktop state. Live playback remains a
specific authorization gate; browser or synthetic fixture checks cannot complete it.
