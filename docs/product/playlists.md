# Playlist behavior

[Product contracts](README.md) · [Safe testing](safe-testing.md)

- The playlist hero starts near the content edge on a gradient derived from the artwork's dominant
  color fading into the near-black canvas (the same treatment album and artist detail headers use),
  with no fixed height: 64-point top and 24-point bottom padding around the artwork and text. Artwork
  is 232 points at 1,000 points wide and above, 192 points from 600 points wide, and otherwise clamped
  between 128 and 192 points, alongside a responsive title. At roughly 840 points wide and above it uses the
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
  clock for Duration and a green sort indicator. Aligned header buttons handle local sorting; rows retain native table selection and context menus, with neutral-gray selection highlights with native active/inactive behavior and rounded neutral-gray hover backgrounds on unselected rows. This local display projection never changes source order. Clicking **Date Added** sorts directly and reverses on the next click through native sorting; it never opens a
  picker or menu.
- Track tables use native multi-selection. **Add to Playlist** is a context-menu command listing
  library playlists whose owner URI matches the signed-in profile. The selected rows are batched
  as one mutation, preserving duplicate track URIs from distinct occurrences and ignoring repeated
  selection IDs.
- In an editable open playlist, Delete/Backspace and **Remove from Playlist** remove the selected
  occurrences by explicit Pathfinder UID (`CatalogTrack.occurrenceUID`), never by display ID or track URI. Read-only playlists do
  not advertise or route those commands. Saved or failed-refresh content cannot establish
  editability, even when it contains an owner or historical occurrence identifiers.
- Successful add/remove invalidates the affected retained playlist, refreshes it if open, and
  reports through `TransientFeedbackPresenter`. A later revisit cannot treat a pre-mutation
  snapshot as fresh; cancelled reconciliation keeps prior rows visibly stale and disables
  occurrence removal. A failed or cancelled request with an uncertain server outcome also marks
  retained rows stale; a definite rejection or stale account/session callback leaves presentation
  unchanged. A committed write remains successful if refresh fails: retain prior rows,
  mark them possibly stale, and let Retry reload without repeating the mutation.
- No playlist drag-and-drop or arbitrary reordering. Native table ownership does not add an
  occurrence-aware multi-selection drag mutation. Use the keyboard-accessible context-menu command.

See [transient mutation feedback](navigation.md#transient-mutation-feedback) for shared banner behavior.
