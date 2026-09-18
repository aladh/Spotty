# Playback presentation

[Product contracts](README.md) · [Safe testing](safe-testing.md)

## Playback presentation and ownership

Rust/librespot owns protocol and engine lifetimes, Swift owns policy/presentation, and AVFoundation
renders decoded PCM; see [engine ownership](../architecture/playback-engine-ownership.md).

- Automatically mirror the active Connect owner's track, artists, artwork, position, transport,
  queue, and available controls, including another computer, without manual refresh.
- An identified remote owner adds a thin green player-shelf strip naming its device and playing/
  paused state. Hide it for local/unidentified ownership; it supplements the device menu.
- Controls target the playback owner without silently transferring to this Mac. With a retained
  track but no active device, a remembered remote owner remains an uncertain remote candidate.
  Missing/stale fallback never implies local ownership.
- When this Mac is ready and listed, nothing is playing, and no active device or remote candidate
  exists, show This computer as the green default with “Ready to play”. Opening Spotty never
  activates/transfers playback. Explicit Play/Resume then uses the local engine without device
  selection, even with a retained track; other controls keep ownership-based routing. Unidentified
  playing state requires device selection; known remote candidates stay remote.
- Resume validates displayed track/context/paused position against the engine. Cold joins restore
  the session paused, including queue/options, and play only after matching local-player evidence.
  Never substitute a track or restart at zero. VoiceOver announces the ready card as “Default
  device”; hide it while commands are unavailable. Without a displayed track it accepts a new
  selection, but the player shelf's Play stays disabled.

### System media controls

- Play/Pause, Previous, and Next media keys share Playback-menu admission and routing. Explicit
  system Play/Pause are idempotent and never transfer playback.
- System Now Playing mirrors title, artist, duration, position, transport, and identified remote
  ownership. macOS chooses the active media app.
- Sign-out, disconnection, or quit clears system metadata and disables commands. Closing a window
  retains controls while Spotty runs. Demo/tests never register system media commands.

### Transport and progress

- Unmodified Space toggles once while browsing, including when held. Text editing, focused native
  controls, sheets, and dialogs retain normal Space behavior. Keyboard and menu actions share admission/routing.
- Use a black 72-point player shelf, 56-point artwork, 14-point titles, 12-point artist/time labels,
  and a 32-point Play button. Center progress and scale it with width; keep the owner strip separate.
  Queue/device icons are 16-point filled glyphs in adjacent 32-point targets: 70% white at rest,
  white on hover, and #1ed760 with a 4-point dot while open. Connect uses a computer glyph for
  remote computers and device/speaker otherwise.
- Queue and Connect share one inspector. The other icon switches contents; the active icon or
  header close button closes it and clears its indicator. Retain Recently played when switching.
  Connect shows the current device in a dark card and available devices in 56-point rows, this
  computer first. Selecting a device explicitly transfers playback and leaves the inspector open.
- With no track, disable Play. Show Pause only for observed playing state. Pending resume retains
  track, context, position, and modes through local loading/timing and empty activation observations
  until Spotify confirms playback. Stale/unavailable/unconfirmed resume stays paused with a durable
  “choose a track or playlist” notice; disable stale Play until new playback clears it. The active
  playlist stays green in sidebar/Home while paused; disconnect/cleared track removes it.
- A failed current local track load explains how to retry or choose another track through existing controls, without
  raw upstream errors or permanent-unavailability claims. Suppress notices for preload/superseded
  requests, stale lifetimes, and observations behind newer optimistic targets. Show the notice above
  controls with keyboard dismissal and a VoiceOver announcement. It never reconnects or changes
  credentials; dismissing an older notice cannot clear a newer one.
- Explicit audio-key refusal followed by decoder failure stops that attempt, preserves the queue,
  and asks the user to retry later. Never auto-skip subsequent tracks; ordinary unavailability stays separate.
- Order controls: shuffle, previous, Play/Pause, next, repeat. Previous/next use track-skip symbols
  with an outside bar, not rewind/fast-forward.
- Use a Spotify-styled native slider with keyboard/VoiceOver adjustment and elapsed/total
  description. Authoritative snapshots drive idle position. Dragging owns the thumb and commits
  once; track/account/engine/owner changes reject obsolete gestures. Disabled playback cannot seek.
- Interpolate confirmed playing progress with [Core Animation](../../Sources/Spotty/Views/PlaybackProgressDrawing.swift),
  without per-frame SwiftUI layout. Small drift leaves animation running; larger drift eases to
  correction. Pause, seek, and track/owner changes re-anchor immediately. During interaction the native
  slider owns position/commit; interpolation neither
  changes playback state nor sends seeks.
- Shuffle is one on/off control with persistent fewer-repeats policy. No style picker: Connect has
  no shuffle-style parameter.
- Repeat cycles off → queue → track → off using the reducer's raw context/track flags. Send only
  changed flags. Ordinary track → off changes one; both-true → off clears both. Queue → track
  changes context off before track on. If the second mutation fails after the first succeeds,
  best-effort restore captured flags and report failure. Keep later authoritative target snapshots
  and unrelated newer states. Otherwise compensate known intermediate states: off after failed
  queue → track restores queue; `(context: false, track: true)` after failed both-true → off
  restores the captured track mode and both-true flags.

### Catalog Play controls

Home quick-access, shelf and grid cards expose Play beside their primary action.
The green control appears on hover or keyboard/accessibility focus; assistive technology can discover it at rest. Keep Play and navigation separate, with native focus and no nested buttons. Tab reaches each action; Space activates it once per press. Focus reveals the control through
both the page and shelf without undoing later manual scrolling. Use a 40-point quick-access control
and the existing 48-point artwork-overlay control. Hidden controls do not intercept pointer navigation.
When playback is unavailable, expose a disabled control and dim its visible treatment; card
navigation remains usable. The account-fenced runtime pauses/resumes the current selection at its
retained position and starts another, revalidating retained controls against current authority.
Cards, sidebar and expanded/compact details reflect this with glyphs, labels and availability.
Track cards match the track URI; collections match context, never membership. Menu Play still starts
the selection.

See [Queue behavior](queue.md) for ordering and occurrence-safe mutations.
