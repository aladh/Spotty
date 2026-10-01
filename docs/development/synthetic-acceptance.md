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

## GUI shell regression

```bash
./Scripts/check-gui-regression.sh --output .build/gui-regression-local --expected-head "$(git rev-parse HEAD)"
```

Use a new output directory and a logged-in macOS GUI session. This development gate builds the
Debug browsing harness in the shared `.build` after the Swift gate, then runs the browsing and
signed-out fixtures through the actual Spotty scene. Each disposable `dev.spotty.gui-test-host`
bundle uses injected synthetic dependencies, with no transport, mutation, audio, or network use.
It is an unsandboxed, ad-hoc-signed test host; it cannot attest App Sandbox isolation. The separately
signed, network-denied Demo workflow remains the owner of that evidence.

The runner bounds each GUI attempt to 90 seconds and the complete invocation to five minutes.
Missing GUI access fails; it never substitutes a skip or a previous report. It captures the exact
LaunchServices app PID and executable/start identity for the unique bundle, then retires only that
verified host and its own bounded `open -W -n` wrapper. Runtime stdout/stderr are retained separately
from launcher/signing logs. Failed discovery never guesses an app PID. Existing Demo and live Spotty
processes remain outside its ownership.

`summary.json` and each run's `gui-evidence.json` retain source stability, launch/fixture/build/engine
identity, failure reasons, and references to original reports and logs. Passing requires all eight
browsing or four signed-out checkpoints, every declared geometry and rendered-chrome assertion,
and zero commands, playing, and mutations throughout. Current-process own-window compositor PNGs
bind the rendered padding checks to each window; separate view captures help diagnose failures.
These assertions do not establish full visual parity, live playback, or audible output.
The inactive checkpoint transfers key ownership to an empty fixture window while the app stays active;
switching between applications remains separate interactive verification.

## Semantic UI smoke

```bash
./Scripts/smoke-synthetic-ui.sh
```

This uses the signed, isolated Demo with the GUI browsing fixture. It requires a logged-in macOS
desktop and existing Accessibility permission for the invoking terminal or Codex, without Screen
Recording or permission changes. `--preflight` compiles the driver and checks permission without
launching an app. `--run-root RUN_ROOT` attaches only to the exact owned signed Demo process;
the unsandboxed CI GUI test host is not accepted.

The [public Accessibility driver](../../Scripts/synthetic_ui_smoke.swift) exercises Home, Search
filters, selection-only Songs, album detail, repeated Back/Forward, rapid query replacement and
clear/recovery, then Focus/Deep Work. It revalidates process/run identity, synthetic dependencies,
verified network sandbox, and fresh status before actions, with a post-action status barrier proving
command and mutation counts remain unchanged. It never activates transport or media keys.

Readiness waits allow 15 seconds per checkpoint within a 120-second action deadline. The wrapper
bounds the single driver attempt to 135 seconds and retains partial checkpoints and baseline/observed
safety state in `.build/browsing-runs/run.*/ui-smoke.json`. Reusing same-run evidence fails.
Close the Demo after pass or failure. This proves the declared flow, not visual parity or live playback.
