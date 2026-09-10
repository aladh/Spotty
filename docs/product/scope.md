# Product scope

[Product contracts](README.md) · [Safe testing](safe-testing.md)

## Product direction

- Apply the **80/20 product principle**: aim to cover the most-used listening workflows—roughly
  80% of everyday value—with roughly 20% of the implementation and maintenance cost of full
  feature parity. These proportions are a prioritization heuristic, not measured targets.
  Favor a small, coherent feature set; defer rarely used features and options whose value does
  not justify their complexity. Evaluate additions by frequency of use, user-visible benefit,
  and ongoing cost. This principle never relaxes account/privacy/session safety, playback and
  lifetime correctness, truthful state, Spotify familiarity, or native macOS interaction.
- Spotty is a focused native macOS client for personal Spotify Premium use; macOS is its only
  target. Use SwiftUI and AppKit for Spotify-familiar surfaces and native interaction. Do not add
  a WebView, Chromium runtime,
  cross-platform shell, or second UI framework. Do not add a supported Spotify API fallback.
- Match the official Spotify desktop app as closely as practical for supported workflows:
  artwork-led headers, dense
  track tables, a right Queue/Connect rail, and a full-width player shelf. The app is dark-only,
  with a near-black canvas and no appearance mode or theme system. Preserve macOS inactive-window,
  focus, keyboard selection, and accessibility behavior without adopting unrelated system colors.
  Fixed green denotes media actions, current playback, and the
  ready local Connect destination.
- Keep the surface small: no in-app volume control, manual refresh, Settings scene, or custom
  accent-color preference. Playlist creation, renaming, cover editing, collaborative permissions,
  and arbitrary reordering are out of scope. Occurrence-safe add/remove is allowed only for
  playlists Spotty can establish it owns.

## Visual fidelity and interaction

Spotify familiarity is a product requirement, not optional inspiration. Preserve recognizable
layout, proportions, density, typography, palette, iconography, and hover/selection states.
The 80/20 principle limits feature scope; it does not authorize redesigning supported workflows.
Native macOS APIs should supply keyboard, focus, accessibility, windowing, and control tracking.
Style those controls to match Spotify when possible. A framework default is not a product requirement.

For appearance changes, identify the affected Spotify desktop reference and compare the same
surface and states before and after. Record the reference version/date or image provenance and
any intentional difference. When a current reference is unavailable, retain the established
appearance and report that limit; do not invent a redesign. A behavior fix should preserve existing
appearance unless the request authorizes a visual change. If fidelity conflicts with safety,
accessibility, or platform constraints, make the smallest necessary deviation and explain it.
Do not rewrite the visual contract merely to legitimize an implementation's side effect.
