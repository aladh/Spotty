# Search

[Product contracts](README.md) · [Navigation](navigation.md)

- Keep All, Artists, Songs, Albums, and Playlists filters above the results. All starts with
  a short Songs preview, then artwork shelves; Show all opens the matching filter. Songs uses a
  full-height native table with artwork, artist links, album links, and durations. Narrow layouts
  hide the album column. Song ordinals follow [row playback controls](playlists.md#row-playback-controls).
  Other filters show artwork grids with circular artist portraits.
  Keep returned duplicate cards distinct, including their scroll anchors.
- The short Songs preview uses its artwork for Play/Pause: pause the playing current track,
  resume the paused current track, or start another track. Reveal the control on hover or keyboard
  focus, retain accessibility access at rest, and disable activation during disconnection or pending
  commands. Return, double-click, and context-menu Play retain their start-from-the-beginning behavior.
  Tab enters the available artwork control of one selected, loaded preview row; Shift-Tab returns to
  native selection. Tab from the control continues through the window's focus order; multiple selection
  and rows without a loaded control follow normal window order.
- Filtering reuses the current query's results. Returning from details retains successful results,
  filter, song selection, and scroll; a new query clears result interaction while keeping its filter.
  Clearing Search returns to the empty prompt and All. Account replacement retires search state.
- Retrying the same completed query keeps its rows, selection, and scroll while fetching replacements.
  Failed categories retain their previous results with a retry notice; successful empty responses clear
  that category. A different query or session cannot reuse the old query's rows; credential refusal
  clears retained results and fences other responses from that search, then shows the error and retry
  in every category.
  Try Again is disabled while disconnected or while a search is running.
- Empty and failed results describe the selected category; partial failures keep other results usable.
  Search remains pending through debounce and in-flight reads. Clear Search keeps keyboard focus in the field.
