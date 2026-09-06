# Playback presentation

[Product contracts](README.md) · [Safe testing](safe-testing.md)

## Playback presentation and ownership

- Follow [engine ownership](../architecture/playback-engine-ownership.md): Rust/librespot owns the playback protocol,
  Swift owns policy/presentation, and AVFoundation renders decoded PCM through the narrow adapter.
- Spotty mirrors the active Spotify Connect device automatically, including a device owned by a
  different computer. The now-playing title, artist, artwork, position, play/pause state, queue,
  and available controls must follow that owner without requiring a manual refresh.
- An identified remote owner adds a thin green strip to the player shelf that names the device and
  its playing or paused state. It disappears for local or unidentified ownership and does not
  replace the device menu.
- Transport commands target the device that owns playback. Spotty must not silently transfer
  playback to this Mac merely because the user pressed a remote control. When no device is marked
  active but a current track remains, a remembered last remote device stays an uncertain remote
  candidate so commands remain remote-routable; a missing or stale fallback never becomes local.
  If this Mac has joined Connect but the playback owner is unidentified, commands direct the user
  to choose a device, including This computer for local playback, rather than claiming startup is
  still in progress. Selecting a device is the explicit recovery path.
### System media controls

- macOS Play/Pause, Previous, and Next media keys use the same capabilities and Connect routing
  as the Playback menu. Explicit system Play and Pause are idempotent. They never transfer playback.
- The system Now Playing surface mirrors the current title, artist, duration, position, and transport
  state, including an identified remote Connect owner. macOS chooses the active media app.
- Signing out, losing the connection, or quitting clears system metadata and disables commands.
  Closing the window leaves media controls available while Spotty continues running.
- The isolated demo and automated tests do not register system media commands.

### Transport and progress

- The black player shelf is 80 points tall, with 56-point artwork, 14-point track titles,
  12-point artist/time labels, and a 32-point play button. The centered progress area scales
  with window width; the remote-owner strip remains separate. Queue and device-chooser icons
  use 16-point filled glyphs in adjacent 32-point targets, with 70% white at rest and white on hover.
  Open controls use #1db954 with a 4-point dot and brighten to #1ed760 on hover. Connect shows a
  computer glyph for a remote computer owner and the device/speaker glyph otherwise.
  Queue and Connect share one inspector: selecting the other icon switches its contents, selecting
  the active icon closes it, and the header close button clears the active indicator. Queue retains
  its Recently played tab when switching to Connect. Connect shows the current device in a dark
  card and available devices in 56-point rows, with this computer first. Selecting an available
  device invokes the existing explicit transfer action and keeps the sidebar open.

- With no current track, Play is disabled. Pause appears only for observed playing state.
- If the active local engine cannot load its current requested track, show an actionable playback
  notice explaining that the user can retry or choose another track through the existing playback
  and browsing controls, without raw upstream details or a claim of permanent
  unavailability. Preload failures, superseded requests, stale account/engine lifetimes, and
  observations held behind a newer optimistic play target must not surface that notice. The notice
  appears above the player controls with a keyboard-accessible dismiss button and a VoiceOver
  announcement; it does not reconnect or change credentials. Dismissal of an older notice must
  not clear a newer one.
- The transport order is shuffle, previous, play/pause, next, repeat. Previous and next use the
  track-skip symbols with an outside bar, not rewind or fast-forward symbols. Repeat stays to the
  right of Next.
- Interpolate progress smoothly between authoritative playing snapshots. New snapshots, seeks,
  pauses, track changes, and ownership changes re-anchor it.
- Shuffle is a single on/off control using Spotty's persistent fewer-repeats policy. There is no
  style picker because Connect exposes no shuffle-style parameter.
- Repeat cycles off → queue → track → off. Each step sends only the Connect flags that change,
  planned from the reducer's raw context/track pair rather than the display mode. Ordinary
  track-repeat (context off, track on) → off is one mutation; a both-true track snapshot → off
  clears both flags. Queue → track is the only two-flag step and applies context off before track
  on. If the second mutation fails after the first was accepted, Spotty best-effort restores the
  captured previous flags and still reports failure. A later snapshot of the requested target is
  kept; the known intermediate off after a compensated queue → track failure restores queue
  repeat; a compensated both-true track → off failure whose intermediate snapshot is still
  displayed as track (`context: false`, `track: true`) restores the captured previous track
  mode and both-true flags; unrelated newer authoritative repeat state is left intact.

See [Queue behavior](queue.md) for ordering and occurrence-safe mutations.
