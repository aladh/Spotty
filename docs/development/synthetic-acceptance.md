# Synthetic acceptance

[Verification](verification.md) · [Safe testing](../product/safe-testing.md)

The versioned [manifest](../../Tests/BrowsingHarness/Scenarios/manifest.json) assigns stable IDs to
existing workloads. Each entry names its product contracts, initial world JSON, actions, assertions,
isolation, deadline, terminal condition, and evidence. The validator in
[acceptance_scenarios.py](../../Scripts/acceptance_scenarios.py) owns schema version 1 and rejects
unknown fields, duplicate IDs, unsafe dependencies, unbounded deadlines, and paths outside the repo.
Change a scenario version when its declared behavior changes; retain its ID for the same outcome.
Legacy JSON workloads remain supported.

```bash
python3 Scripts/acceptance_scenarios.py list
python3 Scripts/acceptance_scenarios.py run --output .build/acceptance-local
./Scripts/browse-synthetic.sh --scenario playback.recovery
```

Use a new output directory for each run. The default state corpus includes signed-out restore,
browsing/revisits, and playback/recovery. It uses the existing Swift Testing host, production state
intake, and injected Demo services. Normal checks retain their complete suite ownership. The signed
Demo command additionally runs the existing window/scroll workload and verifies its network sandbox.
Neither path constructs live account, engine, network, or audio dependencies.

## Acceptance and holdouts

```bash
python3 Scripts/acceptance_scenarios.py run --corpus all --output .build/acceptance-final
python3 Scripts/acceptance_scenarios.py summary --output .build/acceptance-final
```

CI and the reusable acceptance workflow explicitly select both corpora. Holdouts are excluded from
default implementation runs; this public repository does not make their source secret. The first
variation changes stale playback observation ordering and fixture size. A seeded boundary error
tests assertion sensitivity through production intake: it is a fault-injection proof, not evidence
that the shipping product currently has that defect.

Each invocation makes one attempt. Per-scenario deadlines cancel cooperative state work; the
outer test-host watchdog supplies the process deadline if an operation cannot be cancelled.
Named Demo workloads receive the same scenario deadline and retain the GUI runner's report wait bound.
A failure packet identifies the scenario, checkpoint, expected/observed state, and partial timeline.
Fix the failure and run a fresh attempt; no agent framework or automatic source-edit retry loop is
introduced. A timed-out or missing run cannot reuse a previous report as success.

## Evidence and review

`summary.json` records the manifest digest, checkout revision, PR head when supplied by CI,
tracked-diff digest, full source digest (including nonignored untracked files), source stability,
and every requested scenario outcome. `evidence-ID.json` retains normalized state assertions,
command/observation timeline, forbidden-mutation results, and references to `runtime-ID.json`.
Missing reports and failed test hosts produce failed evidence. CI retains these files and concise
summaries. The test host does not establish App Sandbox, UI, live Spotify, or audible-output behavior.

Automated Demo runs retain `report.json` and add `evidence.json`, including sandbox verification,
build identity, visible workload checkpoints, and available process/profiler artifacts. Timings stay
diagnostic unless a declared, matching configuration establishes a comparison; a single run is not
a performance budget. No screenshot or model judgment replaces auth, playback, or lifetime assertions.

Behavior-changing PRs declare affected contracts, representative IDs run, IDs added or changed, and
unverified acceptance surfaces with reasons. Thermos compares these declarations with the manifest
and the latest matching CI artifact. Pending, dirty, stale, or missing evidence does not establish
passing behavior. See [agent reviews](agent-reviews.md) for trust and coverage limits.

## Semantic UI smoke

```bash
./Scripts/smoke-synthetic-ui.sh
```

This separate command requires a logged-in macOS desktop and Accessibility permission for the
invoking terminal or Codex; it does not need Screen Recording. Permission preflight happens before
Demo build or launch and writes a machine-readable failure when unavailable. The public Accessibility
driver expands Focus, opens Deep Work, waits for the loaded playlist, presses Play then Pause, and
asserts that Play is available again. It validates the run UUID, PID, process start, executable, bundle, and synthetic
configuration before actions. Readiness has a 15-second bound, actions 75 seconds, and the driver
process 90 seconds. `ui-smoke.json` is saved in the run directory. The Demo remains open on pass or
failure; close it when done. This proves the declared UI flow, not visual parity or live playback.
