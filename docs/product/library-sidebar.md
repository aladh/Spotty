# Library sidebar

[Product contracts](README.md) · [Window and navigation](navigation.md)

- Preserve custom playlist order and nested folders across pagination, with local expansion and four
  concurrent folder requests. After account verification, show the complete saved library, even empty,
  during refresh; otherwise show progress. Failed refresh preserves rows and interaction, with a
  stale/error indicator. Credential failure clears saved content; cached ownership cannot enable edits.
  Retain the flat catalog for navigation and playlist actions.
- Arrows select folders without navigating; Return toggles expansion.
  Navigation clears folder focus; account changes clear focus and expansion.
  Tab enters the selected row's available artwork or folder disclosure control; Shift-Tab returns
  to native row selection, and another Tab continues through the window's focus order.
- Use opaque near-black backgrounds, 48-point artwork, 16-point titles, muted 14-point owner/fallback
  labels, and native keyboard selection/scrolling. Rows use pointing hands; artwork reveals Play/Pause
  on hover or focus, accessible at rest. Other areas open details. Neutral-gray selection
  preserves native active/inactive behavior; darker hover applies only to unselected rows.
- The active playlist has a green title and trailing green speaker for local and Connect playback,
  regardless of navigation selection or paused state. Clear them on disconnect, cleared
  current track, or context change; see [playback state](playback.md#transport-and-progress).
  Keep Home/Search in the toolbar; omit separate Your Library destinations and app-name headers.

## Empty and failed loads

- Show an empty-library message only after a successful result. A live empty library says
  “No playlists yet”; a saved empty library says “No saved playlists” and distinguishes an ongoing
  refresh from potentially outdated content. Do not turn an unknown initial result into empty success.
- When a load fails and no rows are available, show a readable error and Try Again, including failed
  refreshes of a saved empty library. Enable retry only while connected and not refreshing, using
  the existing account-scoped request owner. Old-account controls cannot start a retry for a
  replacement account. Retrying shows initial progress if no result has loaded, or the saved-empty
  message during refresh. Populated saved rows remain visible throughout refresh and failure.
- Keep placeholders compact, centered, and readable within the resizable sidebar. Preserve its
  near-black canvas, muted secondary text, native keyboard focus, and disabled-button semantics.
