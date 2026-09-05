# ADR 002: Atomic playback state and explicit dependency ownership

Status: accepted on 2026-08-23.

## Context

Callbacks and suspended requests can outlive their starting state. Independent presentation-field
writes can mix lifetimes and make stale work appear current.

## Decision

- Keep one reducer-owned `SpottyDomain` playback presentation snapshot. Observations carry their
  account/engine lifetime and applicable source revision; the reducer decides whether to apply them.
- Give account lifecycle, queue authority, catalog requests, and commands explicit owners with
  read-only projections. Suspended work revalidates its lifetime before applying results.
- Assemble production dependencies at the app composition root. Views and feature stores use
  injected ports; they do not construct authentication, network, or C playback dependencies.
- Keep PCM delivery outside observable presentation state. Transient mutation feedback also has a
  separate owner; it is not playback state or a general event bus.
- Keep portable policy in `SpottyDomain`, concrete app adapters in `SpottyCore`, and the executable
  launcher thin. Test targets do not ship.

## Tradeoffs

Explicit stamps and owners cost coordination but make cancellation, stale results, and source
precedence testable without a live account. A single mutable controller or independently writable
snapshots would hide those relationships.

A separate infrastructure target is not justified solely by folder organization: the adapters share
private transport models, while injected ports and import checks enforce the useful boundaries.

## Implementation and evidence

See [engine ownership](playback-engine-ownership.md) for responsibilities, the
[enforcement inventory](architecture-enforcement.md) for checks and scoped rules, and
[ADR 003](ADR-003-playback-command-effects.md) for command task ownership.
