# ADR 002: Atomic playback state and explicit dependency ownership

Status: accepted on 2026-08-23. [ADR 008](ADR-008-headless-session-runtime.md) supersedes the original
`PlaybackStore` ownership, MainActor execution, and target placement. This record retains the
current atomic reducer, lifetime, and projection decisions.

## Context

Callbacks and suspended requests can outlive their starting state. Independent presentation-field
writes can mix lifetimes and make stale work appear current.

## Decision

- Keep one reducer-owned `SpottyDomain` playback presentation snapshot. Observations carry their
  account/engine lifetime and applicable source revision; the reducer decides whether to apply them.
- Suspended work revalidates its lifetime before applying results. Playback work uses the
  runtime's `stillCurrent`; [catalog owners](ADR-009-account-catalog-retention.md) fence browsing
  reads and writes. A site deliberately bypassing its owner explains why.
- Assemble production dependencies at the app composition root. Views and feature stores use
  injected ports; they do not construct authentication, network, or C playback dependencies.
- Keep PCM delivery outside observable presentation state. Transient mutation feedback also has a
  separate owner; it is not playback state or a general event bus.
- Dependencies run one way; test targets do not ship. Runtime, lifecycle, and target ownership
  follow ADR 008; the [ownership map](../playback-engine-ownership.md) links their implementations.

## Tradeoffs

The reducer snapshot is not observable. `PlaybackReducer.apply` reports acceptance and changes,
including per-component acceptance inside a Connect cluster. The runtime drives follow-ups from
that report rather than rediscovering acceptance by diffing published state. It prepares equatable
semantic, queue, device, and timing projections; the desktop applies one coherent publication.
Source watermarks remain internal; timing-only samples update only the timeline. Views read
projections, while command and lifetime decisions read the reducer snapshot. Local
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

## Implementation and evidence

See [engine ownership](../playback-engine-ownership.md) for responsibilities, the
[enforcement inventory](../enforcement.md) for checks and scoped rules, and
[ADR 003](ADR-003-playback-command-effects.md) for command task ownership.
