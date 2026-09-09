# Spotify boundary agent guidance

Follow the affected [product contract](../../../docs/product/README.md) and
[engine contract](../../../docs/architecture/engine-contract.md) for auth, catalog, Connect, queue,
and playback boundaries.

## State, effects, and dependencies

- Follow [ADR 002](../../../docs/architecture/adrs/ADR-002-playback-state-and-dependencies.md) for
  reducer-owned state, lifetime revalidation, injected dependencies, and transient feedback.
- `PlaybackCoordinator` serializes commands and `PlaybackEffectRegistry` owns store-level tasks.
  Reducer acceptance normally gates follow-ups; only documented same-lifetime transport
  reconciliation may succeed after a rejected finish. Other stale, superseded, teardown,
  cancellation, and epoch-invalidated outcomes stay inert.
## Boundary invariants

- `PlaybackCore.swift` is the only Swift importer of `SpottyPlaybackCore`;
  `RustPlaybackEngine.swift` is its only caller. Keep the C header, Rust exports, ownership, pointer
  lifetimes, callback threading, and typed C snapshots aligned.
- Track identity is the market/requested Spotify track ID. Relinked decode IDs and metadata may
  enrich it but never replace it or create a second identity model.
- Ordered sources carry revisions; account and engine generations reject stale callbacks and
  requests. Do not use `lastRevision: inout`; compare and commit revision state at its owner.
- `RustPlaybackEngine` assigns process-local envelope sequence on one drain. Never call
  `AsyncStream.Continuation.yield` or `onTermination` while the fan-out lock is held.
- `QueueService` owns precedence and context identity. `QueueProtocolProjection` projects upcoming
  rows from unfiltered Connect tracks; metadata must not reorder or erase newer authoritative state.
- Follow the engine contract for typed observations, Swift presentation policy, and the single
  reconnect rehydration sequence. Resume targets come from sticky resume-load URIs via
  `ResumeLoadPlan`, never presentation snapshots.
- Keep read-only catalog access separate from playlist mutation. Writes use `PlaylistMutating` and
  `PlaylistMutationController`; Pathfinder mutation DTOs do not enter views.
- PCM goes directly from the retained engine adapter to `AudioRenderer`, never observable UI state.
  Keep callbacks bounded and never block the Rust callback thread.
- Follow [privacy](../../../PRIVACY.md) for logging; never log credentials or private identifiers.
