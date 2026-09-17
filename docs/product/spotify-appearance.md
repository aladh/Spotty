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

Album references from the same Spotify version were inspected on **2026-09-15**: **FIXION** at
rest and scrolled with a selected row, and **Sun & Moon (Downtempo Version)** at rest. Their large
artwork/title hierarchy, inline release summary, numbered two-line track rows, and compact scrolled
header inform the [album presentation contract](navigation.md#window-and-navigation-behavior).
Spotty shows known play counts, hiding them at narrow widths, and omits unsupported save/download
controls. These references do not establish full feature or visual parity.

Artist reference: Spotify desktop **1.3.0.277**, **Dan be**, inspected on **2026-09-15** at rest
and scrolled through Popular and Discography. The full-width photographic banner, oversized artist
name, verification/listener lines, numbered artwork rows, compact scrolled header, and discography
chips inform the [artist presentation contract](navigation.md#window-and-navigation-behavior).
Spotty uses its shared Play and shuffle controls and omits follow, save, download, Artist pick,
Fans also like and Appears On. The full discography opens a separate page with list/grid
layouts, release-type filters and date/name sorting. Artist play counts are shown when available and hidden at narrow widths.
Radiohead’s full discography, inspected on the same date, supplies the list/grid reference.
The reference captures remain local; synthetic Demo artists provide repeatable inspection fixtures.
The user-supplied **2026-09-16** Dan be screenshot supplies the single-row Discography and Featuring
playlist reference, including descriptions beneath playlist titles.
On **2026-09-16**, Spotify **1.3.0.277** was inspected read-only on Dan be and Angelo Ferreri:
About uses a rounded photographic card with a listener count and biography preview, opening a full biography;
Discovered on and Artist Playlists follow it. Spotty supports these returned playlist rows and an About sheet
with the first gallery image, biography and audience counts; gallery paging, city rankings, social links and
Spotify's profile-authenticity explanation remain outside the supported surface.

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
- **Accessibility:** preserve row position, current-track, sort-direction,
  link, and disabled-state announcements; color alone must not carry the actionable state.
  Verify VoiceOver order through the native/hosted boundary. Native controls and scrolling must
  remain usable. Spotty maintains one animation behavior, without a custom Reduce Motion variant.

Native headers, rows, queue selection, column resizing, and compact-header scrolling require visual
comparison. Shared constants and behavior tests do not certify fidelity. Fix mismatches or review
them as explicit product changes; do not redefine this reference to accept them.
