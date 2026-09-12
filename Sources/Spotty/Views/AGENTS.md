# Native UI agent guidance

Follow [product scope](../../../docs/product/scope.md), [navigation](../../../docs/product/navigation.md),
and the affected [surface contract](../../../docs/product/README.md). Keep supported surfaces visually close to Spotify and information-dense without crowding.

- For dense tables, selection, and scrolling, follow
  [ADR 010](../../../docs/architecture/adrs/ADR-010-native-dense-surfaces.md): AppKit owns these
  surfaces; SwiftUI supplies composition and leaf content.
- Preserve Spotify layout, typography, colors, control proportions, and interaction states. Use
  native macOS APIs for menus, focus, keyboard behavior, accessibility, tracking, and window semantics;
  do not substitute system appearance as a side effect of an interaction repair. Follow the
  [visual fidelity procedure](../../../docs/product/scope.md#visual-fidelity-and-interaction).
- Keep one clear hierarchy. At a glance, the user should know where they are, what is playing, and the
  primary action. Remove persistent controls that do not earn their space.
- Make state honest. Loading, empty, stale, disabled, error, reconnecting, and remote-owner states are
  design requirements. Never show speculative playback state or an action that cannot succeed.
- Preserve selection, focus, scroll position, artwork/content anchors, and useful content across
  refresh, metadata arrival, tab changes, resize, and window activation. Motion explains continuity;
  it does not delay input or decorate chrome.
- Verify the affected keyboard focus, VoiceOver labels/order, reduced motion, active/inactive
  selection, disabled state, truncation, and narrow/window-resize behavior within the authorized
  acceptance scope.
- Views render state and invoke narrow actions. Presentation stores own browsing presentation;
  `SpottySessionRuntime` owns account/playback orchestration under
  [ADR 008](../../../docs/architecture/adrs/ADR-008-headless-session-runtime.md).
  Artwork and header tint use the shared account-stamped provider from
  [ADR 009](../../../docs/architecture/adrs/ADR-009-account-catalog-retention.md); do not start an
  independent network or image-decode pipeline in a view.
