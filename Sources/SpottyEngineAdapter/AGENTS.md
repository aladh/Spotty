# Engine adapter agent guidance

This target is the only one that depends on the `SpottyPlaybackCore` binary. Follow the
[engine contract](../../docs/architecture/engine-contract.md),
[ownership boundary](../../docs/architecture/playback-engine-ownership.md), and
[ADR 001](../../docs/architecture/adrs/ADR-001-playback-engine.md).

- `PlaybackCore.swift` is the only Swift importer of `SpottyPlaybackCore`; `RustPlaybackEngine.swift`
  is its only caller, and `PlaybackCore` stays internal to this target. Keep the C header, Rust
  exports, ownership, pointer lifetimes, callback threading, and typed C snapshots aligned.
- `RustPlaybackEngine` assigns process-local envelope sequence on one drain. Never call
  `AsyncStream.Continuation.yield` or `onTermination` while the fan-out lock is held.
- PCM goes directly from the retained engine adapter to `AudioRenderer`, never observable UI state.
  Keep callbacks bounded and never block the Rust callback thread.
- Depend only on `SpottyDomain` and the binary. Application state, catalog, auth, and presentation
  policy belong in `SpottyCore`; pure policy belongs in `SpottyDomain`.
- Anything `SpottyCore` uses must be `public` with an explicit initializer: it is a separate module,
  and `@testable import SpottyCore` does not expose this target's internals.
- `SpottyLog` and `debugLog` live here because the renderer and engine need them. This is the one
  logging owner; follow [privacy](../../PRIVACY.md) and never log credentials or private identifiers.
