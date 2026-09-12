# Engine adapter agent guidance

This is the only production target with a direct dependency on the `SpottyPlaybackCore` binary.
Follow the
[engine contract](../../docs/architecture/engine-contract.md),
[ownership boundary](../../docs/architecture/playback-engine-ownership.md), and
[ADR 001](../../docs/architecture/adrs/ADR-001-playback-engine.md).

- Keep the C header, Rust exports, ownership, pointer lifetimes, callback threading, and typed C
  snapshots aligned.
- `RustPlaybackEngine` assigns process-local envelope sequence on one drain. Never call
  `AsyncStream.Continuation.yield` or `onTermination` while the fan-out lock is held.
- PCM goes directly from the retained engine adapter to `AudioRenderer`, never observable UI state.
  Keep callbacks bounded and never block the Rust callback thread.
- Depend only on the binary, `SpottyDomain`, shared `SpottyRuntimeContracts`, and `SpottyDiagnostics`.
  Session authority belongs in `SpottySessionRuntime`, private service adapters in `SpottyGateway`,
  and presentation in `SpottyCore`; follow [ADR 008](../../docs/architecture/adrs/ADR-008-headless-session-runtime.md).
- Ports used by `SpottySessionRuntime` cross a module boundary and need explicit visibility and
  initializers. The desktop must not import the engine adapter to bypass the runtime.
- Logging calls still need [privacy review](../../PRIVACY.md): centralized output does not make
  dynamic fields safe to publish.
