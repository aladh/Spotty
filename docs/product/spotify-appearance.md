# Spotify appearance reference

[Product contracts](README.md) · [Visual fidelity policy](scope.md#visual-fidelity-and-interaction)

Preserve the supported Spotify desktop composition and Spotty's established visual language when
changing native view ownership. Surface behavior remains defined by [navigation](navigation.md),
[playlists](playlists.md), [queue](queue.md), and [playback](playback.md#transport-and-progress).

## Reference and evidence

The retained anchors below come from Spotty main
[`993feb5`](https://github.com/aladh/Spotty/tree/993feb51885f94666358d3853f6dfd5b1969dcf8)
and its unchanged shared palette, layout, Home, detail-header, and transport sources. They describe
existing Spotty design choices; they are not new measurements of Spotify.

Spotify desktop **1.2.99.317** was viewed read-only on **2026-09-12**. Only **Home at rest** was
inspected; current native playlist, sidebar, queue, and interaction states remain visually
unverified. This reference does not establish parity for those surfaces or replace the comparison
required by the visual fidelity policy.

## Retained anchors

Dimensions are in points. Keep these relationships while applying the responsive behavior in the
linked surface contracts; fixed values are not a reason to clip content or disable native input.

| Aspect | Retained appearance | Canonical source or contract |
| --- | --- | --- |
| Composition | Black toolbar and full-width player shelf; near-black library, main canvas, and right Queue/Connect rail; artwork-led detail headers. | [Window and navigation](navigation.md#window-and-navigation-behavior), [player shelf](playback.md#transport-and-progress) |
| Palette | White primary text, 70% white secondary text, 64% white data text; canvas RGB `(0.071, 0.071, 0.071)`. Media green RGB `(0.118, 0.843, 0.376)` denotes media actions and accepted playback state. Selection remains neutral. | [SpottyPalette](../../Sources/Spotty/Views/SpottyPalette.swift) |
| Home cards | 160-point artwork with 8-point card padding and 6-point card corners; 16-point title and 14-point secondary text. Quick-access rows use 56-point artwork and 14-point bold titles; shelf headings use 24-point bold text. | [HomeView](../../Sources/Spotty/Views/HomeView.swift), [CatalogLayout](../../Sources/Spotty/Views/CatalogLayout.swift) |
| Playlist density | 24-point outer insets; 40-point artwork in 56-point rows; 36-point column header; 16-point title over 14-point artist, with a 12-point artwork/text gap. Artwork and row highlights have 4-point corners. Keep the hero breakpoints, action sizes, columns, and compact-header behavior specified in the playlist contract. | [Playlist presentation](playlists.md), [baseline playlist rows](https://github.com/aladh/Spotty/blob/993feb51885f94666358d3853f6dfd5b1969dcf8/Sources/Spotty/Views/PlaylistTrackList.swift) |
| Sidebar and rail | 64-point rows around 48-point artwork, 8-point inner padding, and 12-point artwork/text spacing; 16-point title and muted 14-point secondary line. Preserve folder indentation, artwork play controls, and linked credits. | [Navigation contract](navigation.md#window-and-navigation-behavior), [SidebarView](../../Sources/Spotty/Views/SidebarView.swift), [SidePanelView](../../Sources/Spotty/Views/SidePanelView.swift) |
| Icons and controls | Retain the 16-point transport glyph geometry and existing speaker, clock, folder, and sort symbols. Keep the 4-point progress rail and 12-point handle; native focus and hit targets belong to the control, not the visible glyph alone. | [TransportSymbol](../../Sources/Spotty/Views/TransportSymbol.swift), [progress contract](navigation.md#window-and-navigation-behavior), [PlaybackPositionSlider](../../Sources/Spotty/Views/PlaybackPositionSlider.swift) |

## State continuity and acceptance

Resting appearance alone is insufficient. Compare the same content and window width in the
relevant states, using [authorized synthetic or read-only inspection](safe-testing.md).

- **Hover, selection, and inactive windows:** preserve distinct hover and selected treatments.
  Playlist rows inherit white at 10% for unselected hover, 20% for active selection, and 13% for
  inactive selection. Sidebar selection uses its own palette tokens. Links underline and turn
  white on hover; current-track indicators and readable text survive selection and deactivation.
  [Playlist](playlists.md) and [navigation](navigation.md#window-and-navigation-behavior) contracts
  define the applicable differences between surfaces.
- **Focus and disabled controls:** native keyboard focus must remain perceptible, with selection,
  menus, and the deliberate playback actions preserved. Unavailable actions retain truthful
  disabled semantics; hover must not imply that a disabled control can act. The seek control
  keeps its rail without an active handle when disabled. See the [playback input contract](playback.md#transport-and-progress).
- **Narrow layouts:** use the existing sidebar/inspector ranges and hero breakpoints. Text
  truncation must preserve useful hierarchy; table headings must align with cells, remaining
  columns must be reachable, and keyboard-selected rows must stay visible below compact headers.
  [NativeTrackTableContainer](../../Sources/Spotty/Views/NativeTrackTableContainer.swift) implements
  that behavior; its geometry still requires visual comparison.
- **Accessibility and Reduce Motion:** preserve row position, current-track, sort-direction,
  link, and disabled-state announcements; color alone must not carry the actionable state.
  Verify VoiceOver order through the native/hosted boundary. With Reduce Motion enabled, progress
  continues to report accepted positions while its continuous interpolation is suppressed, as in
  [PlaybackPositionSlider](../../Sources/Spotty/Views/PlaybackPositionSlider.swift). Native control
  and scrolling behavior must remain usable.

The new native catalog header/row drawing, explicit queue selection drawing, column resizing, and
compact-header scrolling are candidates for visual acceptance against these retained anchors.
Shared constants and behavioral tests do not certify their rendered fidelity. A mismatch must be
fixed or reviewed as an explicit product change; do not redefine this reference to accept it.
