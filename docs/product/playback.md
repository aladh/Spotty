# Playback presentation

[Product contracts](README.md) · [Safe testing](safe-testing.md)

## Playback presentation and ownership

Spotty mirrors the active Spotify Connect device, including remote playback, without a manual
refresh. Track information, progress, queue, transport state, and available controls must agree on
that owner. An identified remote owner is named in the player; unidentified ownership must not be
presented as local.

Transport commands target that owner and never silently transfer playback to this Mac. A remembered
remote device may remain an uncertain routing candidate when no active owner is reported, but a
missing or stale fallback never authorizes local playback. Engine and app responsibilities follow
[engine ownership](../architecture/playback-engine-ownership.md).

### Transport and progress

- Disable Play without a current track, and show Pause only for observed playing state. Keep the
  transport order shuffle, previous, play/pause, next, repeat, with track-skip rather than
  rewind/fast-forward controls.
- Progress interpolates between authoritative playing observations and re-anchors on new
  observations, seeks, pauses, track changes, and ownership changes.
- Shuffle is a persistent on/off policy favoring fewer repeats. There is no style picker because
  Connect exposes no shuffle-style parameter.
- Repeat cycles off → queue → track → off. Partial failures report failure and best-effort restore
  the previous mode without overwriting a newer authoritative state. Protocol flag ordering and
  compensation cases belong in the [transition implementation](../../Sources/Spotty/Spotify/RepeatTransitionApplication.swift)
  and [behavior checks](../../Tests/SpottyBoundaryTests/RepeatTransitionChecks.swift).
- Queue and Connect share one inspector: switching controls changes its contents, selecting the
  active control closes it, and closing it clears the active indicator. Queue retains its Recently
  played selection across switches. Connect lists this computer first; selecting an available
  device explicitly transfers playback and leaves the inspector open.

A failed current local track load shows an actionable, dismissible notice offering retry or another
track through existing controls. Do not claim permanent unavailability, expose upstream details,
reconnect, or change credentials. Preload failures, superseded requests, stale lifetimes, and
observations behind a newer optimistic target must not raise the notice. Announce it to VoiceOver,
keep dismissal keyboard-accessible, and never let dismissal of an old notice clear a new one.

See [queue behavior](queue.md) for ordering and occurrence-safe mutations. The
[views](../../Sources/Spotty/Views) own player dimensions and visual treatments.
