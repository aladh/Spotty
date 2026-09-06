# Window and navigation

[Product contracts](README.md) · [Safe testing](safe-testing.md)

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
- Closing the main window does not quit Spotty. The app remains in the
  Dock and reopens through the Dock icon or the standard macOS Window command.
- Sign Out stays in the macOS **Spotty** menu, including while connecting or after a session
  failure. Teardown drains accepted authorization persistence before clearing the grant.
- Launch restoration retries transient engine startup failures after one and three seconds,
  both with cached streaming credentials and after refreshing them from the saved grant.
  Retries stay within the account connection lifetime; sign-out cancels them and definitive
  credential rejection stops them. Exhaustion shows the connection failure without deleting the grant.

## Transient mutation feedback

- User-initiated mutations, including Add to Queue, report through the one app-composed
  `TransientFeedbackPresenter`; playlist and queue management share it.
- The banner is a single non-modal overlay just above the persistent player. It must not steal
  focus, intercept unrelated pointer or keyboard input, or shift window layout. A newer message
  replaces the current one; automatic dismissal is cancellable and must not clear a replacement.
- Durable connection, playback, session, and command-reconciliation status stay with their existing
  owners (including `PlaybackNotice` / now-playing status text). Do not turn those strings into
  toasts.
