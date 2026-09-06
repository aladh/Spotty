# Safe acceptance testing

[Product contracts](README.md) · [PR acceptance](../../CONTRIBUTING.md#pr-acceptance)

PR readiness uses the [acceptance criteria](../../CONTRIBUTING.md#pr-acceptance).
The live-account guidance below governs separately authorized interactive verification; it does not
create a manual PR acceptance gate.

Spotify Connect controls a live account and can interrupt playback on another device. Playback and
account mutations are therefore **opt-in**, not part of routine acceptance testing.

### Default: automated and read-only

Without explicit playback permission, it is safe to:

- run `./Scripts/check.sh` and the non-shipping Swift test targets;
- launch, sign in, browse Home/Search/library/detail pages, sort tables, inspect devices and queue,
  and close/reopen the window;
- observe remote playback state without pressing Play/Pause, Previous, Next, Shuffle, Repeat,
  Seek, Add to Queue, Transfer, Add to Playlist, or Remove from Playlist.

Transport, seek, transfer, queue/library/playlist/follow mutation, and sign-out each require explicit
current-request authorization naming that action.

Do not infer playback permission from a request to launch, inspect, accept-test, or test read-only.
Do not transfer playback, alter the queue, seek, or change transport modes as a substitute for a
read-only assertion.

### Explicit playback test

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
