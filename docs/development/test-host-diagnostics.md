# Swift test-host diagnostics

Use the [normal verification entry point](verification.md) and preserve its first failure. A last
printed test is a lead, not attribution: stdout can be buffered while another test or process is active.
The [#585 investigation](https://github.com/aladh/Spotty/issues/585) records the historical evidence
and remaining uncertainty. New observations cannot retrospectively establish an old stall's cause.

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
concrete `.xctest` bundle directory or its `Contents/MacOS` executable; unknown or ambiguous layouts
report driver fallback. A launcher sample does not establish the executing host's runtime cause.

Sampler work has its own deadline and owned cleanup. Timeout and interruption preserve their original
status while joining required cleanup; unavailable sampling does not turn a failed test into success.
PID-based sampling still cannot atomically bind process birth at the operating-system call. Record
that limit even when the sample header matches the target.

## Opt-in executing-host observation

The observer wraps one unchanged verification command. Use a new output directory and the actual
produced build root, not a guessed bundle name:

```sh
python3 Scripts/swift_test_host_observation.py \
  --output-dir /tmp/spotty-host-observation-NEW \
  --build-root "$PWD/.build" -- ./Scripts/check.sh
```

The outer deadline is at most 900 seconds; each native watchdog has 300 seconds. Configure tools
through the normal setup procedure first. CI limits the observer to 840 seconds inside its unchanged
15-minute step, reserving 60 seconds for owned cleanup and receipt writes. Do not extend deadlines or retry merely to hide a failure.
For a bounded Gateway investigation, pass the verified target selector after `--` and use its actual
isolated build root. `--help` describes arguments; arbitrary existing output directories are refused.

An enabled diagnostic function immediately writes its invocation nonce, function identity and
PID/parent/group, then returns. Ordinary gates intentionally skip this opt-in function. Observation
requires its exact completed native event, concrete event path in the same observed launch ancestry,
fresh owned kernel identity and real bundle beneath the supplied build root. The reporter adds no
sleep or gate: a host that exits before observation is explicitly unavailable.

`result.json` separates command status from observer status and records proof or refusal, native
events and cleanup. A failed command retains its status. A successful command with unavailable proof
fails the requested observation. Final receipt failures also fail closed. Keep the original packet,
including failed attempts, before changing source or planning a separately declared diagnostic run.

The adapter never starts a sampler. In CI it explicitly refuses native sampling. A same-repository
PR with `host-observation-evidence` requests observation around the existing full native lane; its
artifact upload and readiness checks fail closed. This adds no second macOS matrix and removes no
native tests or acceptance scenarios. Local real sampling demonstrations require separately bounded,
owned synthetic work and identity proof; the historical investigation links their evidence.

Before sharing a report, retain only necessary synthetic identities, source/toolchain/SDK and engine
pin provenance, command meaning, event boundaries, elapsed time and remaining owned work. Keep raw
process arguments and unrelated inventory out of the report under [PRIVACY.md](../../PRIVACY.md).

## Presented Home probe

The opt-in `HomePresentedMeasurementChecks` probe requires the exclusive native build/UI lane. Set
`SPOTTY_HOME_PRESENTED_REPORT` to a fresh path for each process and
`SPOTTY_HOME_PRESENTED_SECTIONS` to 12 or 120. It
captures only its current-process owned 900×600-point window, retains bounded timestamps/digests
instead of pixels, and uses injected catalog/artwork/account/playback services. It does not prove
the earliest usable frame, full keyboard readiness, unobscured visibility, App Sandbox isolation,
or live performance. Its unique synthetic detail label and selection callback are one bounded
readiness check; geometry, discovery, the single AX press and callback acceptance share the
existing ten-second prerequisite deadline. Failures retain a `.failure.json` sidecar.

Build/list the Boundary target with the identical optimized Debug/native flags in
[runtime acceptance](runtime-acceptance.md#measurements), then identify the actual owned `.xctest` bundle before opting into presentation. SwiftPM's linker signature alone
may not seal bundle resources and can fail strict verification. Preserve that failure and artifact;
prepare only this disposable synthetic bundle with the existing ad-hoc fixture signing method:

```sh
codesign --force --timestamp=none --sign - "$probe_bundle"
codesign --verify --deep --strict "$probe_bundle"
```

Record source/pin/flags and the sealed executable's SHA256/CDHash before running the probe through
`verify.py test` with identical flags and `--skip-build`. Verify signature/hash again afterward.
Do not relink or reseal between admission and measurement, change signing identities or grants,
weaken strict verification, or retry a failed gate merely to obtain a result. Signature verification
establishes artifact integrity; it does not establish isolation or successful measurement.
