# ADR 010: Direct AppKit ownership for dense browsing surfaces

Status: accepted on 2026-09-12.

## Context

Dense playlist, catalog, sidebar, and queue surfaces need predictable occurrence selection,
scrolling, focus, hit targets, and update behavior. Depending on the internal AppKit hierarchy of
a SwiftUI List or Table makes these behaviors depend on structure Spotty does not own.
Native ownership is not a reason to substitute macOS default styling for Spotify's presentation.

## Decision

Own the important dense tables and their scroll containers directly with AppKit. `NSTableView`
owns row reuse, native selection, column sorting, keyboard handling, menus, and scrolling. SwiftUI
remains the composition and leaf-content layer for headers, cards, status, and other simple views.
Playlist header scrolling and its compact pinned header belong to the owned scroll container,
not an observer searching SwiftUI's private view hierarchy.

Use occurrence IDs for selection, context-menu targets, and updates. Display sorting and filtering
must preserve source order and duplicate occurrence identity. Relevant metadata changes update the
affected visible presentation; timing-only playback samples must not rebuild dense rows. Sidebar
folder expansion remains local; queue ordering remains the runtime's accepted ordering.

Apply the existing [Spotify visual contract](../../product/scope.md#visual-fidelity-and-interaction),
[playlist behavior](../../product/playlists.md), and [navigation contract](../../product/navigation.md)
to these native controls. Preserve dimensions, dark palette, artwork, typography, pointer regions,
hover/selected/current states, inactive-window readability, native focus, and accessibility. Native
selection and scrolling are implementation ownership choices, not approval for a product redesign.

Window-local route state restores playlist search, table sort, occurrence selection, and scroll
position on a retained revisit. Refresh and enrichment prune only identities that no longer exist
or are filtered out. Account replacement retires that interaction state.

## Tradeoffs and verification

Direct ownership adds responsibility for cell reuse, row drawing, layout, accessibility,
tracking, and lifecycle cleanup. It removes reliance on undocumented ancestor discovery, but does
not by itself prove responsiveness or visual fidelity. Check the affected keyboard, VoiceOver,
hover, selected, focus, disabled, inactive, narrow, resize, and Reduce Motion behavior against the
same Spotify reference or established baseline.

A diffable data source, row reuse, or fewer invalidations is not a frame-rate measurement. Any
performance claim requires a fresh optimized comparison with source/engine identity, workload,
window and display conditions, and separate rendering/input metrics. Keep historical experiments
in the [performance baseline](../performance-baseline.md) distinct from acceptance evidence.
