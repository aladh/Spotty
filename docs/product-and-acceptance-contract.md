# Product and acceptance contract

This contract defines product behavior and safe live-account testing. Spotty is unofficial and
independent, with no affiliation, endorsement, or sponsorship from Spotify AB; its private
integration may violate Spotify's terms. See [ADRs](architecture-decisions.md) for architecture and
[playback engine ownership](playback-engine-ownership.md) for measured baselines.

## Product direction

- Apply the **80/20 product principle**: aim to cover the most-used listening workflows—roughly
  80% of everyday value—with roughly 20% of the implementation and maintenance cost of full
  feature parity. These proportions are a prioritization heuristic, not measured targets.
  Favor a small, coherent feature set; defer rarely used features and options whose value does
  not justify their complexity. Evaluate additions by frequency of use, user-visible benefit,
  and ongoing cost. This principle never relaxes account/privacy/session safety, playback and
  lifetime correctness, or native macOS behavior and truthful state.
- Spotty is a focused native macOS client for personal Spotify Premium use; macOS is its only
  target. Prefer SwiftUI and AppKit over custom chrome, and do not add a WebView, Chromium runtime,
  or second UI framework.
- Use a Spotify-familiar composition without copying Spotify pixels: artwork-led headers, dense
  track tables, a right Queue/Connect rail, and a full-width player shelf. The app is dark-only,
  with a near-black canvas and no appearance mode or theme system. Preserve macOS inactive-window,
  focus, and selection behavior. Fixed green denotes media actions and current playback only.
- Keep the surface small: no in-app volume control, manual refresh, Settings scene, or custom
  accent-color preference. Playlist creation, renaming, cover editing, collaborative permissions,
  and arbitrary reordering are out of scope. Occurrence-safe add/remove is allowed only for
  playlists Spotty can establish it owns.

## Window and navigation behavior

- New windows start on Home with search unfocused. Navigation selection is not restored across
  launches. Playlists open from the sidebar; there is no separate playlist grid destination.
- The main window has a native, resizable sidebar and inspector. The sidebar begins near 208 points and the
  inspector near 280; their ranges are 180–260 and 260–360 points respectively. The library stays visible; a native
  command can show or hide the inspector.
- A black top bar shares the window-control row and contains back/forward history, Home, and a persistent rounded search field.
  Home and Search live in that bar; the library sidebar uses an opaque neutral near-black surface.
  Navigation history clears when the account changes. Command-[ and Command-] navigate history;
  Command-L focuses search.
- The sidebar reads Spotify’s saved custom playlist order and folder hierarchy. Folder rows
  expand and collapse locally, including nested folders, without changing the Spotify library.
  Sibling order follows the service across pagination; folder failures preserve the previous
  complete library rather than publishing a partial tree. The flat playlist catalog remains
  available for detail navigation and playlist actions.
  Rows use 48-point artwork, a 16-point title, and a muted 14-point owner or fallback label, with
  native keyboard selection and scrolling. Sidebar rows use a pointing-hand cursor and reveal
  a play button over playlist artwork on hover; clicking the rest of the row opens its details.
  Selection uses an inset, rounded charcoal highlight;
  hover uses a darker surface. Home and Search remain in the top bar; the sidebar
  has no separate Your Library destinations or app-name header.
- The near-black inspector presents Queue and Recently played as text tabs with a green active
  underline. Rows use 48-point artwork beside title and artist; available duration and history
  timestamps remain in accessibility descriptions without narrowing the visible title column.
  Playlist-sourced upcoming tracks show “Next from:” with the known playlist name as a link
  to its detail view. The link follows accepted playback context and never starts playback.
  Queue artist credits and playlist artist/album names navigate to their catalog pages. Each
  known artist is a separate link; links underline and turn white on hover, with a pointing-hand
  cursor. Missing destination metadata stays plain text. Queue row hover also uses the pointer.
  Playlist table cells retain the arrow except for links; playback buttons and the seek bar use
  a pointer when enabled. Hovering the seek bar reveals a white handle and green played portion.
  Current and upcoming queue rows show an inset rounded highlight and dimmed artwork with a
  play/pause button on hover. Row clicks still select; the artwork
  button, Return, or double-click invokes playback.
  Queue ordering and history content retain their existing playback-owned sources.
- Closing the main window purges presentation caches but does not quit Spotty. The app remains in the
  Dock and reopens through the Dock icon or the standard macOS Window command.
- Sign Out stays in the macOS **Spotty** menu, including while connecting or after a session
  failure. Teardown drains accepted authorization persistence before clearing the grant.
- Launch restoration retries transient engine startup failures after one and three seconds,
  both with cached streaming credentials and after refreshing them from the saved grant.
  Retries stay within the account connection lifetime; sign-out cancels them and definitive
  credential rejection stops them. Exhaustion shows the connection failure without deleting the grant.

## Playback presentation and ownership

- Follow [engine ownership](playback-engine-ownership.md): Rust/librespot owns the playback protocol,
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
### Transport and progress

- The black player shelf is 88 points tall, with 56-point artwork, 14-point track titles,
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
### Queue

- A queue refresh started before the first Connect snapshot must preserve and hydrate the newer
  Connect ordering when it arrives, including when the Web request fails. Metadata hydration cannot
  replace that ordering with its captured startup fallback.
- Playback is the queue's ordering authority. Catalog and Web API metadata may enrich names but
  cannot reorder it; resolvable entries progressively replace fallback `Unknown` labels.
- Upcoming queue rows use a native selectable list. Delete/Backspace and **Remove from Queue**
  remove only selected *upcoming* occurrences by queue identity (Connect occurrence uid when
  present), never by track URI. Duplicate URIs or duplicate UIDs that cannot be proven fail
  closed. The now-playing row and Recently played tab are not removable queue entries. Play from the queue
  remains a deliberate primary action (Return/double-click), not a single-click.
- Queue replacement calls Spotify Connect `set_queue` with remaining protocol `next_tracks`, current
  `prev_tracks`, and the exact incoming ProvidedTrack metadata map (`metadata`, `uid`, `provider`,
  and every other snapshot player.proto field). Never synthesize `is_queued` or alter presentation
  state to imply success. Sequential Add to Queue is non-atomic and reports full, zero, or partial
  completion.
  Removal requires a complete Connect mutation snapshot, matching account/engine epoch and owner,
  and no `disallow_set_queue` or `disallow_removing_from_next_tracks` reason. Partial, provisional,
  web-API-only, restricted, joining, local-owner, stale-selection, and rejected requests retain the
  visible queue and report through `TransientFeedbackPresenter`. While authoritative replacement is
  in flight, silently refuse another removal: cancelling the local task cannot undo an accepted
  `set_queue`. Cancelled or account-epoch-invalidated in-flight removals also retain the queue
  without transient feedback.
- Local-owner removal is disabled: librespot `Spirc` at the pinned revision exposes append and
  clear operations, but not selected-occurrence removal, and inbound `SetQueue` is not a public
  local command. Any future support must remain within
  the retained engine boundary and pass focused checks. Add to Queue remains available for local
  and remote owners, including multiple selected tracks in visible order.

## Playlist behavior

- The playlist hero starts near the content edge on a roughly 230-point dark blue-gray gradient,
  with roughly 170-point artwork and a responsive title. At roughly 840 points wide and above it uses the
  96-point heavy title treatment, while preserving compact breakpoints and long-title scaling. It shows
  the loaded plain-text description and known owner, song count, and aggregate duration without
  inferring visibility. Its action strip has a 56-point green Play button, the existing shuffle
  toggle, and an expandable local playlist search at the right. Search matches title, artist, or
  album without changing source order or occurrence identities; hidden selections are cleared.
  Matches are highlighted; result ordinals and hero count/duration reflect the filtered rows.
  Clear retains focus; Escape clears a query, then collapses an empty field. Empty search also
  collapses when focus leaves.
  The hero and action strip scroll with the tracks. Once they leave the viewport, a 64-point
  compact playlist title and green Play button pin above the column headings; scrolling back
  restores the expanded header without resetting track selection or order.
  Foregrounds remain readable in inactive windows.
- The owner, song count, and total duration share the metadata line beside the artwork when the
  current playlist snapshot is authoritative. Song count does not belong in the track table.
- Playlist rows use native Spotify-familiar columns: `#`, `Title` (40-point artwork beside
  stacked Artist), `Album`, `Date Added`, and `Duration`. Artwork stays in Title. `#` shows the
  one-based display position and becomes a speaker only for a playing current URI. A paused current
  URI keeps its green ordinal; selected rows retain native selection foregrounds. Accessibility
  exposes the position in either current state.
  Playlist row durations round each track to the nearest second for display, and the hero's total
  sums those same rounded per-track seconds. Totals of at least one hour use `hr`/`min` units;
  player and progress formatting retain their existing floor-to-second behavior.
  Shared search, library, and album tables retain their separate Artist, Popularity, BPM, Key, and
  Time columns.
- Playlist tables initially show newest Date Added first, matching Spotify's Recently added view.
  Rows have a 56-point minimum height, no row separators, and a quiet 36-point header with a
  clock for Duration and a green sort indicator. Aligned header buttons handle local sorting; rows retain native list selection and context menus, with rounded neutral-gray hover and selected backgrounds instead of the system blue highlight. This local display projection never changes source order. Clicking **Date Added** sorts directly and reverses on the next click through native sorting; it never opens a
  picker or menu.
- Track tables use native multi-selection. **Add to Playlist** is a context-menu command listing
  library playlists whose owner URI matches the signed-in profile. The selected rows are batched
  as one mutation, preserving duplicate track URIs from distinct occurrences and ignoring repeated
  selection IDs.
- In an editable open playlist, Delete/Backspace and **Remove from Playlist** remove the selected
  occurrences by Pathfinder UID (`CatalogTrack.id`), never by track URI. Read-only playlists do
  not advertise or route those commands.
- Successful add/remove refreshes only the affected open playlist and reports through
  `TransientFeedbackPresenter`. Failed, cancelled, and stale account/session writes leave
  presentation unchanged. A committed write remains successful if refresh fails: retain prior rows,
  mark them possibly stale, and let Retry reload without repeating the mutation.
- No playlist drag-and-drop: SwiftUI Table serializes the dragged row, not occurrence-aware
  multi-selection, and disabled drop targeting was not verified without private hit-testing or pixel
  coordinates. Use the keyboard-accessible context-menu command.

## Transient mutation feedback

- User-initiated mutations, including Add to Queue, report through the one app-composed
  `TransientFeedbackPresenter`; playlist and queue management share it.
- The banner is a single non-modal overlay just above the persistent player. It must not steal
  focus, intercept unrelated pointer or keyboard input, or shift window layout. A newer message
  replaces the current one; automatic dismissal is cancellable and must not clear a replacement.
- Durable connection, playback, session, and command-reconciliation status stay with their existing
  owners (including `PlaybackNotice` / now-playing status text). Do not turn those strings into
  toasts.

## Safe acceptance testing

PR readiness uses the [acceptance criteria](../CONTRIBUTING.md#pr-acceptance).
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

Handle test data and artifacts according to [PRIVACY.md](../PRIVACY.md) and
[SECURITY.md](../SECURITY.md).
