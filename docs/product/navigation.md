# Window and navigation

[Product contracts](README.md) · [Safe testing](safe-testing.md)

## Window and navigation behavior

- New windows start on Home with search unfocused. Navigation selection is not restored across
  launches; account changes clear history. Command-[ and Command-] navigate history, and Command-L
  focuses the persistent search field. Home and Search belong in the top bar.
- Keep a native, resizable library sidebar and inspector. The library remains visible; the
  inspector can be shown or hidden through a native command. Playlists open from the sidebar,
  without a separate playlist-grid destination.
- Preserve Spotify's custom playlist order and nested folders across pagination. Expanding a folder
  is local navigation, not a library mutation. Failed loads retain the last complete library.
  Clicking a playlist opens it; its artwork play button is a distinct playback action.
- The inspector offers Queue and Recently played. “Next from:” links to the accepted playback
  context without starting playback. Known artist and album destinations are individually
  navigable; missing destinations remain plain text. Keep duration and history timestamps
  accessible even when omitted from the visible row.
- Queue row clicks select. Artwork controls, Return, and double-click invoke playback. Links and
  enabled playback controls have clear hover affordances without turning the entire track table
  into a button.
- Closing the main window releases presentation caches but does not quit Spotty. Reopen it through
  the Dock or standard Window command.
- Sign Out remains in the **Spotty** menu while connecting or after failure. It drains accepted
  authorization persistence before clearing the grant. Launch restoration retries transient failures
  within the account lifetime; sign-out and definitive credential rejection stop retries. Exhaustion
  presents the failure without deleting the saved grant.

## Transient mutation feedback

User-initiated playlist and queue mutations share one non-modal banner above the player. It must
not steal focus, intercept unrelated input, or shift layout. New feedback replaces old feedback;
dismissal or cancellation of an old message must not clear its replacement.

Durable connection, session, playback, and reconciliation status remain with their owning surfaces.
Do not turn those states into transient banners or add another event bus.

Layout and styling are owned by [RootView](../../Sources/Spotty/RootView.swift) and the
[views](../../Sources/Spotty/Views); shared appearance constraints are in [product scope](scope.md).
