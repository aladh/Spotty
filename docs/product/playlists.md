# Playlist behavior

[Product contracts](README.md) · [Safe testing](safe-testing.md)

## Browsing and selection

The hero shows artwork, a responsive title, plain-text description, and known owner, song count,
and duration from the authoritative playlist snapshot. Do not infer visibility. It scrolls with
the tracks; a compact title and Play control remain available once the hero leaves the viewport.
Changing header presentation must preserve selection, order, and inactive-window readability.

Local search matches title, artist, or album without changing source order or occurrence identity.
Clear hidden selections, highlight matches, and reflect filtered rows in display ordinals and totals.
Clear retains focus; Escape clears a query before collapsing an empty field. An empty field also
collapses when focus leaves.

Playlist tables expose position, title/artwork/artist, album, date added, and duration. The current
playing row shows a speaker; a paused current row keeps its ordinal. Position remains accessible in
either state. Start with newest Date Added first; column sorting is local and never reorders the
playlist. Date Added sorts directly rather than opening a menu. Duration totals use the same rounded
per-track seconds as the rows; player progress has its own timing convention.

Use native multi-selection and context menus. Shared catalog tables retain their separate metadata
columns. [PlaylistDetailView](../../Sources/Spotty/Views/PlaylistDetailView.swift) and the
[table views](../../Sources/Spotty/Views) own layout values, typography, and responsive breakpoints.

## Mutations

- **Add to Playlist** lists owned library playlists. Batch selected occurrences in visible order,
  preserving duplicate tracks while ignoring repeated selection IDs.
- In an owned open playlist, Delete/Backspace and **Remove from Playlist** remove selected
  occurrences by their service identity, never by track URI. Read-only playlists must not advertise
  or route these commands.
- Successful writes refresh only the affected open playlist. Failed, cancelled, or stale-lifetime
  writes leave presentation unchanged. If a committed write's refresh fails, retain the rows and
  mark them possibly stale; Retry reloads without repeating the mutation.
- Drag-and-drop is out of scope: the supported alternative is the keyboard-accessible context menu.
  Native table dragging did not provide reliable occurrence-aware multi-selection and disabled-target
  behavior without private hit testing.

Mutations use the shared [transient feedback](navigation.md#transient-mutation-feedback).
