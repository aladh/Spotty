# Engine adapter agent guidance

This target is the only one that depends on the `SpottyPlaybackCore` binary. Follow the
[engine contract](../../docs/architecture/engine-contract.md),
[ownership boundary](../../docs/architecture/playback-engine-ownership.md), and
[ADR 001](../../docs/architecture/adrs/ADR-001-playback-engine.md).

- Keep the C header, Rust exports, ownership, pointer lifetimes, callback threading, and typed C
  snapshots aligned. The compiler owns the target boundary; source policies own access within it.
- `RustPlaybackEngine` assigns process-local envelope sequence on one drain. Never call
  `AsyncStream.Continuation.yield` or `onTermination` while the fan-out lock is held.
- PCM goes directly from the retained engine adapter to `AudioRenderer`, never observable UI state.
  Keep callbacks bounded and never block the Rust callback thread.
- Depend only on `SpottyDomain` and the binary. Application state, catalog, auth, and presentation
  policy belong in `SpottyCore`; pure policy belongs in `SpottyDomain`.
- Anything `SpottyCore` uses must be `public` with an explicit initializer: it is a separate module,
  and `@testable import SpottyCore` does not expose this target's internals.
- Logging calls still need [privacy review](../../PRIVACY.md): centralized output does not make
  dynamic fields safe to publish.
