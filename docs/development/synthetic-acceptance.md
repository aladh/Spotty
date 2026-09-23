# Synthetic acceptance

[Verification](verification.md) · [Safe testing](../product/safe-testing.md)

The versioned [manifest](../../Tests/BrowsingHarness/Scenarios/manifest.json) assigns stable IDs to
workloads and declares their contracts, assertions, and safety limits.
[acceptance_scenarios.py](../../Scripts/acceptance_scenarios.py) owns the schema and validation,
including unique IDs, synthetic dependencies, bounded deadlines, and repository-local inputs.
Change a scenario version when its declared behavior changes; retain its ID for the same outcome.
Legacy JSON workloads remain supported.

```bash
python3 Scripts/acceptance_scenarios.py list
python3 Scripts/acceptance_scenarios.py run --output .build/acceptance-local
./Scripts/browse-synthetic.sh --scenario playback.recovery
```

Use a new output directory. The default corpus covers signed-out restore, browsing, and playback
recovery through the Swift test host with synthetic services. The signed Demo additionally exercises
window/scroll behavior and verifies its network sandbox. Neither path uses live accounts, engine,
network, or audio.

## Acceptance and holdouts

```bash
python3 Scripts/acceptance_scenarios.py run --corpus all --output .build/acceptance-final
python3 Scripts/acceptance_scenarios.py summary --output .build/acceptance-final
```

CI and the reusable acceptance workflow select both corpora; default runs exclude holdouts.
The manifest owns variations, whose source is public. Seeded boundary faults test assertion
sensitivity through production intake; they do not demonstrate shipping defects.

Each invocation makes one attempt. Deadlines and caller cancellation retire cooperative state work;
the test-host watchdog bounds uncooperative operations. Named Demo workloads keep the scenario
deadline and GUI report-wait bound. Failures retain the checkpoint, expected/observed state, and
partial timeline. Fix the failure and run afresh; missing or timed-out runs cannot reuse old success.

## Evidence and review

`summary.json` binds outcomes to the checkout revision, supplied PR head, manifest/source digests,
and source stability, including nonignored untracked files. `evidence-ID.json` retains assertions,
timeline, isolation results, and references to `runtime-ID.json`. CI retains failed evidence for
missing reports or failed hosts. Test-host results do not establish App Sandbox, UI, live Spotify,
or audible-output behavior.

Automated and profiled Demo runs retain the original `report.json` when produced and write
`demo-evidence.json`, even when scenario preparation, preflight, or build fails. Set
`SPOTTY_BROWSING_RUN_ROOT_FILE` to a writable file to receive the run directory as soon as it exists.
For early failures, inspect stderr and `profiler-state.json` when present; an app report or launch
manifest may not exist yet.

Passing Demo evidence requires verified sandbox isolation and valid, matching manifest/report
identities for the run, source, build, engine, fixture, and layout. Malformed or mismatched evidence
fails the launcher, preserves completed checkpoints, and references available process/profiler
artifacts. A corrupt report cannot claim success.

Demo reports are local evidence; the CI/Thermos collector consumes only corpus summaries.
Timings require a declared, matching [comparison](runtime-acceptance.md#visible-instruments-captures);
a single run is not a performance budget. Screenshots and model judgment cannot replace assertions.

Follow [PR declarations](../../CONTRIBUTING.md#pull-request-execution) and
[review evidence requirements](agent-reviews.md#evidence-and-coverage). Pending, dirty, stale, or
missing evidence cannot establish passing behavior.

## Semantic UI smoke

```bash
./Scripts/smoke-synthetic-ui.sh
```

This requires a logged-in macOS desktop and Accessibility permission for the invoking terminal or
Codex, without Screen Recording. Preflight reports missing permission before building or launching.
The [public Accessibility driver](../../Scripts/synthetic_ui_smoke.swift) revalidates Demo identity
before actions: expand Focus, open Deep Work, await the playlist, press Play then Pause, and assert
Play is available again. Readiness waits allow 15 seconds per checkpoint within the driver's
75-second action deadline. The [wrapper](../../Scripts/smoke-synthetic-ui.sh) bounds the driver
process to 90 seconds; `ui-smoke.json` identifies the outcome. Close the Demo after pass or failure.
This proves that flow, not visual parity or live playback.
