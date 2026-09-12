# SpottyCore agent guidance

Follow [state and dependency ownership](../../docs/architecture/adrs/ADR-002-playback-state-and-dependencies.md)
and [runtime ownership](../../docs/architecture/adrs/ADR-008-headless-session-runtime.md) for composition
and task lifetimes. Spotify and Views have narrower guidance.

- Keep top-level composition declarative. `PlaybackStore` adapts runtime publications on MainActor;
  account/playback authority stays in `SpottySessionRuntime`, private transports in `SpottyGateway`,
  and pure policy in `SpottyDomain`.
- The runtime's `PlaybackEffectRegistry` owns playback task lifetimes and settlement per ADR 003.
  Catalog presentation uses its account-scoped flight owner; it cannot bypass runtime admission.
- Native system adapters dispatch narrow presentation actions into the runtime.
- Add a protocol only at a real system or substitution boundary. Do not rebuild the app around a
  god controller; [ADR 003](../../docs/architecture/adrs/ADR-003-playback-command-effects.md)
  explains the effect architecture.
