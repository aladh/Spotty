# Swift test-host diagnostics

Use [normal verification](verification.md) and preserve its first failure. Buffered stdout makes the
last printed test a lead, not attribution.
The [#585 investigation](https://github.com/aladh/Spotty/issues/585) records historical evidence and
uncertainty. New observations cannot establish an old stall's cause.

## Timeout evidence

The watchdog retains its command, original status, native events, owned-process snapshot and sample
result. Native completion events distinguish execution from skipped probes and discovery; they do not
identify a process. Compare last-started and last-completed events with process evidence before naming
a decoder, scheduler or leaked dependency as the owner.

Before owned cleanup, timeout and interruption packets also retain bounded per-bundle streams from
fresh owned SwiftPM loaders in the conventional temporary output directory. Refused or unavailable
streams have explicit limitations; their absence never changes the command's failure status.

Ownership comes from observed launch ancestry and a kernel birth/image identity, including children
that change process group. Neither a process name, group membership nor PID ordering admits an
unrelated process. Identity is rechecked before sampling or signaling. Known SwiftPM loaders carry a
concrete `.xctest` bundle or `Contents/MacOS` executable; unknown/ambiguous layouts report driver fallback. Launcher samples cannot establish host causes.

Sampler work has its own deadline and owned cleanup. Timeout and interruption preserve their original
status while joining required cleanup; unavailable sampling does not turn a failed test into success.
PID-based sampling still cannot atomically bind process birth at the operating-system call. Record
that limit even when the sample header matches the target.

## Opt-in executing-host observation

Wrap one unchanged command with a new output directory and its actual build root:

```sh
python3 Scripts/swift_test_host_observation.py \
  --output-dir /tmp/spotty-host-observation-NEW \
  --build-root "$PWD/.build" -- ./Scripts/check.sh
```

The outer deadline is at most 900 seconds; each native watchdog has 300 seconds. Use normal tool setup. CI limits the observer to 840 seconds inside its unchanged
15-minute step, reserving 60 seconds for owned cleanup and receipt writes. Do not extend deadlines or retry merely to hide a failure.
For Gateway investigations, use the verified target selector and isolated build root. `--help` describes arguments; existing output directories are refused.

An enabled diagnostic function immediately writes its invocation nonce, function identity and
PID/parent/group, then returns. Ordinary gates intentionally skip this opt-in function. Observation
requires its exact completed native event, concrete event path in the same observed launch ancestry,
fresh owned kernel identity and real bundle beneath the supplied build root. The reporter adds no
sleep/gate; an exited host is unavailable.

`result.json` separates command status from observer status and records proof or refusal, native
events and cleanup. A failed command retains its status. A successful command with unavailable proof
fails the requested observation. Final receipt failures also fail closed. Keep the packet,
including failed attempts, before changing source or planning a separately declared diagnostic run.

The adapter never samples; CI explicitly refuses native sampling. A same-repository
PR with `host-observation-evidence` requests observation around the existing full native lane; its
artifact upload and readiness checks fail closed. This adds no second macOS matrix and removes no
native tests or acceptance scenarios. Local real sampling demonstrations require separately bounded,
owned synthetic work and identity proof; the historical investigation links their evidence.

Before sharing a report, retain only necessary synthetic identities, source/toolchain/SDK and engine
pin provenance, command meaning, event boundaries, elapsed time and remaining owned work. Keep raw
process arguments and unrelated inventory out of the report under [PRIVACY.md](../../PRIVACY.md).

## Presented Home probe

Native probes require the exclusive lane, signed artifact admission, synthetic ports and source/pin/flags/
hashes before and after. Preserve failures. Never change grants or signing identities, weaken verification,
extend deadlines, enable live dependencies or retry for green.

### Actual application lifecycle

Use an interactive, optimized, network-denied Demo with `homePresentedProbeSections: 12`, browsing
mode, eight uniquely labeled albums per shelf and nil artwork. Default mode diagnoses traversal/navigation, not performance.

Compile before launch:

```sh
xcrun swiftc -parse-as-library -swift-version 6 -warnings-as-errors \
  Scripts/synthetic_home_ax.swift Tests/BrowsingHarness/Support/HomeAXProtocol.swift -o /tmp/home-ax
/tmp/home-ax --preflight
./Scripts/browse-synthetic.sh --optimized --interactive /tmp/home-scenario.json
/tmp/home-ax RUN_ROOT HEAD SOURCE_SHA256 SIGNED_EXECUTABLE_SHA256
```

Existing Accessibility access is required. Fresh connected, visible,
zero-command safety pulses, atomic non-replacing nonce publication and a shared ten-second deadline
admit one exact public detail action. Retire only owned Demo processes; restore the desktop.
Failure receipts preserve rejected values/predicates. Allow bounded cooperative capture shutdown before owned termination.

After launch, call `synthetic_home_startup.wait_for_ready` with `min(batchDeadline, startupOrigin+10s)`
before controller invocation. Missing/stale pulses wait; malformed/unsafe pulses fail. Revalidate
identity afterward. Startup consumes batch time without starting the separate request deadline.

Add `homePresentedMeasurement: true` with 12 or 120 shelves for controlled initial-response measurement.
Home stays suspended until own-window ScreenCaptureKit capture is primed.
Capture and external AX bind the same main window using PID, window number, a temporary run-and-nonce
identifier, and normalized primary-display geometry. The bounded inventory rejects duplicate matches,
malformed values and overflow; missing marker export waits within the original deadline. The identifier
is restored on exit.
External AX confirms an enabled, visible, unique detail target after sections arrive, then
waits for Home sampling and capture to finish before pressing it. A pre-navigation stage receipt is
`home-presented-measurement.json`; functional acceptance requires
`home-measurement-accepted.json` and passing `home-ax-external.json`.

Compare repeated fresh processes at identical geometry, scale, flags and fixture count.
Report external readiness observation separately from retrospective terminal-raster onset. Raster onset
follows the last differing frame and can precede AX observation. Idle events
retain the original display timestamp. Capture retains at most 300 timestamp/digest events.
The AX walk is bounded at 10,000 nodes in measurement mode and 1,500 in diagnostic mode; deadlines stay
unchanged. Footprint/view counts precede navigation, and footprint includes capture buffers, hashing,
AX and sampling overhead. This warm connected scene does not prove cold launch, earliest usability,
loaded-artwork performance, full keyboard readiness, visual parity or live performance.

### Historical standalone probe

The opt-in Boundary `HomePresentedMeasurementChecks` uses `SPOTTY_HOME_PRESENTED_REPORT` (fresh path)
and `SPOTTY_HOME_PRESENTED_SECTIONS` (12 or 120). Its 900×600-point XCTest window has not qualified
native AX readiness; it is not an actual-app baseline. Follow
[runtime acceptance](runtime-acceptance.md#measurements) flags. Preserve strict-signature failures;
only the disposable synthetic bundle may use existing ad-hoc fixture signing. Reverify hashes and
strict integrity before and after execution. Signing establishes neither isolation nor measurement.
