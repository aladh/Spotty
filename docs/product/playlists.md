# Playlist behavior

[Product contracts](README.md) · [Safe testing](safe-testing.md)

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
