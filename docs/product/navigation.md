# Window and navigation

[Product contracts](README.md) · [Safe testing](safe-testing.md)

## Window and navigation behavior

### Navigation and retained content

- New windows open Home with Search unfocused; navigation resets across launches.
  Show loading while checking saved login; offer Connect only when sign-in is needed.
  Playlists open from the sidebar, without a playlist-grid destination.
- Same-account revisits restore retained playlist, album, and artist content immediately. Playlists
  retain search, table sort, occurrence selection, and scroll. Artists retain scroll, Popular selection and
  expansion, and discography filters, sort, layout and list scroll. Filtering clears hidden selections; removed occurrences never
  regain selection. Account changes clear history and interaction state. Retention is bounded;
  evicted routes reload normally.
- Playlists/albums share learned labels for matching tracks across active and retained pages,
  preserving duplicates, order, and interaction state. Refreshed labels do not
  make saved collections current.
- Valid `spotify:` resource URIs and `https://open.spotify.com` links open playlist, album, or
  artist details without playback. Unsupported resources, malformed links, and lookalike hosts
  leave navigation unchanged.
- Complete saved playlist/album results remain usable after offline, timeout, or throttled reads
  only after this process verifies the matching account. Label them possibly out of date, including
  during refresh. Credential or account failures cannot become cached success or expose another
  account's content. No offline sign-in or downloaded music.

### Album and artist pages

- Album headers show artwork, large responsive titles, artist links, year, song count, and runtime.
  Credits follow link behavior below. Scrolling compacts headers to title and Play. Numbered 56-point rows show
  linked artists below titles and optional play counts before duration. Narrow widths hide counts, retaining durations;
  omit repeated album names and thumbnails. Selection, sorting, focus, and retained scrolling match playlists.
  Truncate row durations to seconds; truncate summed original durations once for headers, allowing totals to differ.
- Artists show a full-width banner, large name, and known verification/monthly listeners. Without a banner,
  use a tinted hero and known portrait; omit unknown facts. Hero, Popular, Discography and Featuring share native
  scrolling with Play/shuffle, compacting to title/Play.
- Popular previews up to five ranked 56-point rows, expandable to returned tracks, with artwork, title, duration and
  optional play counts hidden at narrow widths. Label unavailable tracks and disable playback. Preserve native
  selection, Return and double-click behavior.
- Discography previews popular releases in one horizontally scrolling row with type filters and year/type labels.
  Featuring shows Spotify's playlists in order with artwork and descriptions; omit empty rows.
  Show all loads full discography: history-aware list/grid, release filters and date/name sorting. Visible tracks load
  without shifting other content. No follow, save or download controls.

### Window and toolbar

- The native resizable sidebar starts near 208 points (range 180–260); the inspector near 280
  (260–360). Keep the library visible; a native command toggles the inspector.
- The black native toolbar contains history, Home, and persistent rounded Search. AppKit owns
  standard window controls, geometry, and hit targets; do not reposition them. Empty toolbar space
  drags the window and double-clicks to zoom. Command-[ / Command-] navigate history; Command-L focuses Search.
  Enabled history arrows show pointing hands on hover; unavailable directions stay disabled.
  Home/Search controls stay 48 points high with breathing room and native Home focus.
- Closing a window leaves Spotty running in the Dock; Dock and standard Window commands reopen it.
  Sign Out remains in the Spotty menu while connecting or failed. Teardown drains accepted
  authorization persistence before clearing the grant.
- Launch restoration retries transient engine startup after one and three seconds, with cached
  streaming credentials and after grant refresh. Account lifetime bounds retries; sign-out cancels
  them and definitive credential rejection stops them. Exhaustion reports failure without deleting
  the grant.

### Library sidebar

- Preserve Spotify's custom playlist order and nested folders across pagination. Expansion is local;
  folder failure keeps the previous complete library. Share a four-request concurrency limit so
  collapsed folders need not load serially. Show progress for an empty loading library; retain the
  flat catalog for navigation and playlist actions.
- Use an opaque near-black surface, 48-point artwork, 16-point titles, muted 14-point owner or fallback
  labels, and native keyboard selection/scrolling. Rows use a pointing hand; artwork reveals Play
  on hover while the rest opens details. Selection is neutral gray with native active/inactive
  behavior; darker hover applies only to unselected rows.
- The active playlist has a green title and trailing green speaker for local and Connect playback,
  regardless of navigation selection or paused state. Clear them on disconnect, cleared
  current track, or context change; see [playback state](playback.md#transport-and-progress).
  Home and Search stay in the toolbar; omit separate Your Library destinations and an app-name header.

### Queue inspector and player

- Near-black Queue and Recently played text tabs use a green active underline. Rows pair 48-point artwork
  with title and artist; duration and history timestamps stay accessible without narrowing titles.
  Playlist queues show “Next from:” with the known playlist link, following accepted context
  without starting playback. Ordering/history retain playback-owned sources.
- Known queue artists and playlist-table artists/albums link to details; each artist links
  separately. Unknown destinations remain text. Links underline, turn white, and use a pointing
  hand on hover. Queue rows and enabled playback buttons also use the pointer; other playlist
  cells retain the arrow. Native nested pointer regions restore the parent's cursor on exit.
- Current/upcoming queue rows show an inset rounded highlight, dimmed artwork, and Play/Pause on
  hover. Row clicks select; artwork buttons, Return, and double-click start the deliberate action.
- Seeking uses a 4-point gray rail and white played portion. Hover, keyboard focus, or dragging
  reveals a 12-point white handle and green played portion. Enabled seeking uses a pointing hand;
  disabled seeking keeps the rail without an active handle. Preserve native focus/disabled semantics.

## Transient mutation feedback

- User mutations, including playlist management and Add to Queue, share the app-composed
  `TransientFeedbackPresenter`.
- Show one non-modal banner above the player without stealing focus, intercepting unrelated
  input, or moving layout. New messages replace old ones; cancelled dismissal cannot clear a replacement.
- Durable connection, session, playback, and reconciliation status stays with its existing owners
  (`PlaybackNotice`/now-playing text), not transient banners.
