# Window and navigation

[Product contracts](README.md) · [Safe testing](safe-testing.md)

## Window and navigation behavior

### Navigation and retained content

- Windows open Home with Search unfocused; launch resets navigation.
  Show loading while checking saved login; offer Connect for sign-in.
  Sidebar playlists open directly, without grids.
- Same-account revisits restore retained playlists/albums/artists immediately. Playlists
  retain search, sort, occurrence selection, and scroll. Artists retain scroll, Popular selection/expansion,
  and discography filters/sort/layout/list scroll. Filtering clears hidden selections; removed occurrences stay
  unselected. Account changes clear history/interaction state. Retention is bounded; evicted routes reload normally.
- Playlists/albums share learned labels for matching tracks across active and retained pages,
  preserving duplicates, order, and interaction state. Refreshed labels do not
  make saved collections current.
- `spotify:` URIs and `https://open.spotify.com` links open playlist/album/artist details without
  playback. Unsupported resources, malformed links, and lookalike hosts do nothing.
- After current account verification, show complete saved playlist/album results, including empty
  results, during refresh. Label saved content potentially outdated during refresh and
  offline/timeout/throttled failure. Credential refusal clears details pending renewed proof;
  credential/account failures cannot become cached success or expose another account's content.
  Account changes clear retention. No offline sign-in or downloaded music.

### Album and artist pages

Numbered album/artist rows follow [row playback controls](playlists.md#row-playback-controls).

- Album headers show artwork, large responsive titles, artist links, year, song count, and runtime.
  Credits follow links below. Scrolling compacts headers to title/Play. Numbered 56-point rows show
  linked artists below titles and optional play counts before duration; narrow widths hide counts, retaining durations;
  omit repeated album names and thumbnails. Selection, sorting, focus, and retained scrolling match playlists.
  Truncate row durations to seconds; truncate summed original durations once for headers, allowing totals to differ.
- Artists show full-width banners, large names and known verification/monthly listeners; absent banners use
  tinted heroes and known portraits. Omit unknown facts. Hero, Popular, Discography, Featuring and About share native
  scrolling with Play/shuffle, compacting to title/Play.
- Popular previews up to five ranked 56-point rows, expandable to returned tracks, with artwork, title, duration and
  optional play counts hidden at narrow widths. Label unavailable tracks; disable starting/resuming them while
  preserving Pause. Preserve native selection, Return and double-click behavior.
- Discography previews popular releases in one horizontally scrolling row with type filters and year/type labels.
  Featuring shows Spotify's playlists in order with artwork and descriptions; omit empty rows.
  About follows Featuring: gallery image or portrait, monthly listeners, biography preview.
  Click for full biography and follower/listener counts; omit empty sections/unknown facts.
  Discovered on and Artist Playlists follow About when returned, preserving order/descriptions.
  Cards use pointing hands; vertical wheel input scrolls the page, horizontal scrolls the shelf.
  Show all opens full discography: history-aware list/grid, release filters and date/name sorting.
  Loading visible tracks preserves layout. Omit follow/save/download controls.

### Window and toolbar

- The native resizable sidebar starts near 208 points (180–260); inspector near 280 (260–360).
  Keep library visible; a native command toggles inspector.
- The black native toolbar contains history, Home, and persistent rounded Search. AppKit owns
  window controls, geometry, and hit targets; never reposition them. Empty toolbar space
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

- Preserve custom playlist order and nested folders across pagination, with local expansion and four
  concurrent folder requests. After account verification, show the complete saved library, even empty,
  during refresh; otherwise show progress. Failed refresh preserves rows and interaction, with a
  stale/error indicator. Credential failure clears saved content; cached ownership cannot enable edits.
  Retain the flat catalog for navigation and playlist actions.
- Use an opaque near-black surface, 48-point artwork, 16-point titles, muted 14-point owner or fallback
  labels, and native keyboard selection/scrolling. Rows use a pointing hand; artwork reveals Play
  on hover while the rest opens details. Selection is neutral gray with native active/inactive
  behavior; darker hover applies only to unselected rows.
- The active playlist has a green title and trailing green speaker for local and Connect playback,
  regardless of navigation selection or paused state. Clear them on disconnect, cleared
  current track, or context change; see [playback state](playback.md#transport-and-progress).
  Keep Home/Search in the toolbar; omit separate Your Library destinations and app-name headers.

### Queue inspector and player

- Near-black Queue and Recently played tabs use green active underlines. Rows pair 48-point artwork
  with title/artist; duration/history timestamps stay accessible without narrowing titles.
  Playlist queues show “Next from:” with the known playlist link, following accepted context
  without playback. Ordering/history remain playback-owned.
- Known queue artists, playlist-table artists/albums, and player artists link to details individually;
  player title/artwork open the album. Unknown destinations remain noninteractive. Text links underline and turn
  white on hover; all links, queue rows and enabled playback buttons use pointing hands. Other cells retain arrows; nested pointer regions restore the parent cursor on exit.
- Current/upcoming queue rows show an inset rounded highlight, dimmed artwork, and Play/Pause on
  hover. Row clicks select; artwork buttons, Return, and double-click start the deliberate action.
- Seeking uses a 4-point gray rail and white played portion. Hover, keyboard focus, or dragging
  reveals a 12-point white handle and green played portion. Enabled seeking uses a pointing hand;
  disabled seeking keeps the rail without an active handle. Preserve native focus/disabled semantics.

## Transient mutation feedback

- Playlist/queue mutations share `TransientFeedbackPresenter`.
- Show one non-modal banner above the player, preserving focus, input, and layout. New messages
  replace old; cancelled dismissal cannot clear replacements.
- Durable connection/session/playback/reconciliation status stays with existing owners
  (`PlaybackNotice`/now-playing text), not transient banners.
