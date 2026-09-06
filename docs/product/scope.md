# Product scope

[Product contracts](README.md) · [Safe testing](safe-testing.md)

## Product direction

- Apply the **80/20 product principle**: aim to cover the most-used listening workflows—roughly
  80% of everyday value—with roughly 20% of the implementation and maintenance cost of full
  feature parity. These proportions are a prioritization heuristic, not measured targets.
  Favor a small, coherent feature set; defer rarely used features and options whose value does
  not justify their complexity. Evaluate additions by frequency of use, user-visible benefit,
  and ongoing cost. This principle never relaxes account/privacy/session safety, playback and
  lifetime correctness, or native macOS behavior and truthful state.
- Spotty is a focused native macOS client for personal Spotify Premium use; macOS is its only
  target. Prefer SwiftUI and AppKit over custom chrome, and do not add a WebView, Chromium runtime,
  cross-platform shell, or second UI framework. Do not add a supported Spotify API fallback.
- Use a Spotify-familiar composition without copying Spotify pixels: artwork-led headers, dense
  track tables, a right Queue/Connect rail, and a full-width player shelf. The app is dark-only,
  with a near-black canvas and no appearance mode or theme system. Preserve macOS inactive-window,
  focus, and selection behavior. Fixed green denotes media actions and current playback only.
- Keep the surface small: no in-app volume control, manual refresh, Settings scene, or custom
  accent-color preference. Playlist creation, renaming, cover editing, collaborative permissions,
  and arbitrary reordering are out of scope. Occurrence-safe add/remove is allowed only for
  playlists Spotty can establish it owns.
