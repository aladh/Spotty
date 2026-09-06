# Native UI agent guidance

Read [product scope](../../../docs/product/scope.md) and [navigation](../../../docs/product/navigation.md)
for appearance and layout changes, then the affected [surface contract](../../../docs/product/README.md)
for supported actions. Live-account acceptance follows [safe testing](../../../docs/product/safe-testing.md).

## Product taste

Spotty should have quiet confidence: native, visually calm, information-dense without feeling cramped,
and capable without advertising every capability.

- Start with established macOS structure, typography, controls, menus, focus, keyboard behavior,
  accessibility, and inactive-window semantics. Prefer system behavior over custom chrome.
- Keep one clear hierarchy. At a glance, the user should know where they are, what is playing, and the
  primary action. Remove persistent controls that do not earn their space.
- Make state honest. Loading, empty, stale, disabled, error, reconnecting, and remote-owner states are
  design requirements. Never show speculative playback state or an action that cannot succeed.
- Preserve selection, focus, scroll position, artwork/content anchors, and useful content across
  refresh, metadata arrival, tab changes, resize, and window activation. Motion explains continuity;
  it does not delay input or decorate chrome.
- For interaction or layout changes, verify the affected keyboard, accessibility, selection, and
  resize behavior within the authorized acceptance scope.
- Do not use `.draggable`, `.dropDestination`, or `onDrop`; drag-and-drop is deliberately outside the
  current product contract.
- Views render state and invoke narrow actions. They do not construct network/auth/playback
  dependencies or own asynchronous orchestration. Downsample artwork to rendered Retina size, keep
  presentation caches cost-bounded, and release them with the window lifecycle.
