# Spotify boundary agent guidance

Follow the affected [product contract](../../../docs/product/README.md) and
[engine contract](../../../docs/architecture/engine-contract.md) for auth, catalog, Connect, queue,
and playback boundaries.

## State, effects, and dependencies

- Follow [ADR 002](../../../docs/architecture/adrs/ADR-002-playback-state-and-dependencies.md) for
  reducer-owned state, lifetime revalidation, injected dependencies, and transient feedback.
- `PlaybackCoordinator` serializes command execution; registry ownership is in the
  [SpottyCore guidance](../AGENTS.md). Reducer acceptance normally gates follow-ups; only documented
  same-lifetime transport reconciliation may succeed after a rejected finish. Other stale,
  superseded, teardown, cancellation, and epoch-invalidated outcomes stay inert. Command outcomes
  follow [ADR 003 intent outcomes](../../../docs/architecture/adrs/ADR-003-playback-command-effects.md#intent-outcomes).
- Start store tasks with `effects.run` and resume after every `await` through
  `PlaybackStore.stillCurrent`. Do not hand-pick lifetime checks at a call site; express a
  deliberate omission with its scope argument and say why. Catalog requests use
  `AccountScopedSingleFlight` and its named join, scope, and publish policies.
- `PlaybackReducer.apply` reports what a reduction accepted and changed. Drive post-acceptance
  side effects from that report rather than diffing published state or re-asking `accepts`.
- `PlaybackStore` owns the one `SessionTeardownController`. `AccountStore` supplies account
  primitives and reads the `isTearingDown` flag the owner sets; it does not coalesce teardown.
- Views never read the reducer snapshot; they read published projections per
  [ADR 002 tradeoffs](../../../docs/architecture/adrs/ADR-002-playback-state-and-dependencies.md#tradeoffs).
- Session persistence follows [ADR 007](../../../docs/architecture/adrs/ADR-007-session-persistence.md).

## Boundary invariants

- The FFI, fan-out, and audio-rendering invariants live with their code in
  [`Sources/SpottyEngineAdapter`](../../SpottyEngineAdapter/AGENTS.md); this directory consumes that
  target's typed observations and engine ports and never the binary.
- Track identity is the market/requested Spotify track ID. Relinked decode IDs and metadata may
  enrich it but never replace it or create a second identity model.
- Ordered sources carry revisions; account and engine generations reject stale callbacks and
  requests. Compare and commit revision state at its owner.
- `QueueService` owns precedence and context identity. `QueueProtocolProjection` projects upcoming
  rows from unfiltered Connect tracks; metadata must not reorder or erase newer authoritative state.
- Follow the engine contract for typed observations, Swift presentation policy, and the single
  reconnect rehydration sequence. Resume targets come from sticky resume-load URIs via
  `ResumeLoadPlan`, never presentation snapshots.
- Keep read-only catalog access separate from playlist mutation. Writes use `PlaylistMutating` and
  `PlaylistMutationController`.
- Follow [privacy](../../../PRIVACY.md) for logging; never log credentials or private identifiers.
