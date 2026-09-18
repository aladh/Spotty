# Search

[Product contracts](README.md) · [Navigation](navigation.md)

- Keep All, Artists, Songs, Albums, and Playlists filters above the results. All starts with
  a short Songs preview, then artwork shelves; Show all opens the matching filter. Songs uses a
  full-height native table with artwork, artist links, album links, and durations. Narrow layouts
  hide the album column. Song ordinals follow [row playback controls](playlists.md#row-playback-controls).
  Other filters show artwork grids with circular artist portraits.
  Keep returned duplicate cards distinct, including their scroll anchors.
- Filtering reuses the current query's results. Returning from details retains successful results,
  filter, song selection, and scroll; a new query clears result interaction while keeping its filter.
  Clearing Search returns to the empty prompt and All. Account replacement retires search state.
- Empty and failed results describe the selected category; partial failures keep other results usable.
  Search remains pending through debounce and in-flight reads. Clear Search keeps keyboard focus in the field.
