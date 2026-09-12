# Spotify boundary agent guidance

Follow the affected [product contract](../../../docs/product/README.md) and
[engine contract](../../../docs/architecture/engine-contract.md) for auth, catalog, Connect, queue,
and playback boundaries.

## State, effects, and dependencies

- Follow [ADR 008](../../../docs/architecture/adrs/ADR-008-headless-session-runtime.md): this directory
  owns MainActor presentation adapters, not account/playback authority or private wire models.
- Runtime effects, command permits, reducer acceptance, queue precedence, and teardown belong in
  `SpottySessionRuntime`. Views read equatable publications, never the reducer snapshot.
- Catalog presentation requests use `AccountScopedSingleFlight` and its named join, scope, and
  publish policies. Revalidate after suspension; cancellation alone does not prove an older
  account or route can no longer complete.
- [ADR 009](../../../docs/architecture/adrs/ADR-009-account-catalog-retention.md) owns persistent and
  retained catalog freshness. A cached owner or occurrence ID cannot enable a destructive edit.
- Session persistence follows [ADR 007](../../../docs/architecture/adrs/ADR-007-session-persistence.md).

## Boundary invariants

- The FFI, fan-out, and audio-rendering invariants live with their code in
  [`Sources/SpottyEngineAdapter`](../../SpottyEngineAdapter/AGENTS.md); this directory consumes runtime
  publications and must not import the engine adapter or binary.
- Track identity is the market/requested Spotify track ID. Relinked decode IDs and metadata may
  enrich it but never replace it or create a second identity model.
- Ordered sources carry revisions; account and engine generations reject stale callbacks and
  requests. Compare and commit revision state at its owner.
- The runtime's `QueueService` owns precedence and context identity. `QueueProtocolProjection` projects upcoming
  rows from unfiltered Connect tracks; metadata must not reorder or erase newer authoritative state.
- Follow the engine contract for typed observations, Swift presentation policy, and the single
  reconnect rehydration sequence. Resume targets come from sticky resume-load URIs via
  `ResumeLoadPlan`, never presentation snapshots.
- Keep read-only catalog access separate from playlist mutation. Writes use `PlaylistMutating` and
  `PlaylistMutationController`.
- Follow [privacy](../../../PRIVACY.md) for logging; never log credentials or private identifiers.
