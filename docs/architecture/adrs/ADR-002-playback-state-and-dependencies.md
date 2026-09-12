# ADR 002: Atomic playback state and explicit dependency ownership

Status: accepted on 2026-08-23; `PlaybackStore` ownership, MainActor execution, and target-placement
choices are superseded by [ADR 008](ADR-008-headless-session-runtime.md). The atomic reducer,
lifetime, and projection decisions below remain current.

## Context

Callbacks and suspended requests can outlive their starting state. Independent presentation-field
writes can mix lifetimes and make stale work appear current.

## Decision

- Keep one reducer-owned `SpottyDomain` playback presentation snapshot. Observations carry their
  account/engine lifetime and applicable source revision; the reducer decides whether to apply them.
- Give account lifecycle, queue authority, catalog requests, and commands explicit owners with
  read-only projections. Suspended work revalidates its lifetime before applying results.
- Revalidation has one primitive per boundary: `PlaybackSessionRuntime.stillCurrent` for playback-scoped
  store work and `AccountScopedSingleFlight` for catalog requests, both with named scope and
  publish policies. A site that deliberately ignores an owner states which one and why.
- Session teardown has one owner. `PlaybackSessionRuntime` coalesces, orders, and releases the gate;
  `AccountStore` exposes only the account primitives that owner drives.
- Assemble production dependencies at the app composition root. Views and feature stores use
  injected ports; they do not construct authentication, network, or C playback dependencies.
- Keep PCM delivery outside observable presentation state. Transient mutation feedback also has a
  separate owner; it is not playback state or a general event bus.
- Keep portable policy in `SpottyDomain` and the playback binary's Swift boundary in
  `SpottyEngineAdapter`. Runtime, gateway, storage, and presentation target ownership now follows
  [ADR 008](ADR-008-headless-session-runtime.md). Dependencies run one way; test targets do not ship.

## Tradeoffs

The reducer snapshot is not itself observable. `PlaybackSessionRuntime.send` publishes equatable
semantic, queue, device and timing projections from the accepted candidate in the same session
transition. `PlaybackStore` applies the resulting publication on MainActor for UI observation.
`PlaybackReducer.apply` also reports what it accepted and changed — including per-component
acceptance inside a Connect cluster — so the store drives follow-ups from that report instead of
rediscovering acceptance by diffing published state.
Source watermarks remain internal; timing-only samples update only the timeline. Views read those
projections, while command and lifetime decisions continue to read the reducer snapshot. Local
progress interpolation remains in the progress control. System media receives ordinary timing
anchors at most once per second, with semantic changes, seeks and discontinuities bypassing that
budget; MediaPlayer interpolates between anchors.

Connect-cluster observations reduce related device, connection and playback facts into one
candidate before publication. Component revisions remain ordered against player-local and
independent lifecycle callbacks. Account initialization success alone does not publish playback
command readiness before engine identity has been consumed.

Engine fan-out storage is bounded. Equivalent adjacent timing samples can coalesce; lost semantic
history produces an explicit resynchronization with retained current source snapshots. Intake
cancels uncertain commands and reconstructs state with original source revisions and timestamps,
without treating a slow UI consumer as a reason to restart the engine. Replayed facts do not
create new listening history.

Explicit stamps and owners cost coordination but make cancellation, stale results, and source
precedence testable without a live account. A single mutable controller or independently writable
snapshots would hide those relationships.

The earlier choice to keep concrete adapters in the presentation target is superseded by
[ADR 008](ADR-008-headless-session-runtime.md): headless execution and typed gateway snapshots now
provide the substitution boundaries that justify separate targets.

## Implementation and evidence

See [engine ownership](../playback-engine-ownership.md) for responsibilities, the
[enforcement inventory](../enforcement.md) for checks and scoped rules, and
[ADR 003](ADR-003-playback-command-effects.md) for command task ownership.
