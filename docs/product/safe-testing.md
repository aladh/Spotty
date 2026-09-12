# Safe acceptance testing

[Product contracts](README.md) · [PR acceptance](../../CONTRIBUTING.md#pr-acceptance)

PR readiness uses the [acceptance criteria](../../CONTRIBUTING.md#pr-acceptance).
The live-account guidance below governs separately authorized interactive verification; it does not
create a manual PR acceptance gate.

Spotify Connect controls a live account and can interrupt playback on another device. Playback and
account mutations are therefore **opt-in**, not part of routine acceptance testing.

Authorization remains valid throughout the ongoing task for the named actions and limits, including
follow-up messages, unless the user revokes or narrows it. Ask again only when an action exceeds
that scope; a new task does not inherit live-account authorization from an earlier task.

## Spotty Demo: standing authorization

Agents may build, launch, relaunch, browse, and interact with the isolated Spotty Demo whenever
useful, without asking for permission. This includes synthetic control interactions and fixture
changes for verification. Use `./script/build_and_run.sh --demo` for interactive inspection or
`./Scripts/browse-synthetic.sh` for the automated workload. Existing development signing is part
of this workflow; changing signing identities or Keychain configuration is not.

This authorization relies on the demo's synthetic dependencies, separate container and identity,
and network sandbox. Do not weaken that isolation or substitute the live app. Demo controls may
be deliberately disabled or unsupported; testing them cannot establish live playback correctness.
The live-account permissions below apply only to real account actions.

## Spotify read-only reference

Agents may launch the official Spotify app, browse its existing signed-in Home/library/detail
surfaces, inspect visible states, and capture visual references whenever useful without asking.
Use it read-only: do not start or alter playback, seek, transfer, change shuffle/repeat, mutate
queues or libraries, sign out, change settings, or authorize a new account as part of comparison.
If sign-in is required, report the unavailable reference and use the established Spotty baseline.
Keep reference captures local and follow [privacy guidance](../../PRIVACY.md); prefer synthetic
Spotty screenshots for committed or published evidence.

## Default: automated and read-only

Without explicit playback permission, it is safe to:

- run `./Scripts/check.sh` and the non-shipping Swift test targets;
- browse Home/Search/library/detail pages, sort tables, inspect devices and queue, and close/reopen
  the window in an existing live session;
- launch or sign in to live Spotty when authorized for the task; live app replacement follows the
  [launch contract](../../script/AGENTS.md), while Demo and official Spotify reference access retain
  their standing permissions above;
- observe remote playback state without pressing Play/Pause, Previous, Next, Shuffle, Repeat,
  Seek, Add to Queue, Transfer, Add to Playlist, or Remove from Playlist.

Transport, seek, transfer, queue/library/playlist/follow mutation, and sign-out each require explicit
authorization naming that action for the ongoing task.

Do not infer playback permission from a request to launch, inspect, accept-test, or test read-only.
Do not transfer playback, alter the queue, seek, or change transport modes as a substitute for a
read-only assertion.

## Explicit playback test

Only when the user has explicitly allowed playback for the current test:

1. Identify the currently active Connect device and confirm the test will not take over playback
   the user wants to keep elsewhere.
2. If local audio is involved, set macOS output volume to zero before starting.
3. Use a named track or playlist and a short, bounded interval. Do not leave playback running while
   waiting on unrelated work.
4. Pause the device used for the test at the end, including after a failed assertion, and report
   any state that could not be restored.
5. Treat transfer, queue mutation, shuffle/repeat changes, sleep/wake, and output-device changes as
   separately scoped mutations; do not bundle them into a basic playback check.

Handle test data and artifacts according to [PRIVACY.md](../../PRIVACY.md) and
[SECURITY.md](../../SECURITY.md).
