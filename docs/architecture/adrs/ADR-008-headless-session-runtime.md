# ADR 008: Headless session runtime with an in-process desktop client

Status: accepted on 2026-09-12. Supersedes the `PlaybackStore` ownership and MainActor isolation
choices in [ADR 002](ADR-002-playback-state-and-dependencies.md) and
[ADR 003](ADR-003-playback-command-effects.md); their reducer and command-settlement rules remain.

## Context

Account admission, playback, queue authority, recovery, and teardown need one owner independent of
windows and UI scheduling. Moving that owner into a helper process would also require serialization,
helper lifecycle, packaging, and audio-continuity machinery. No measured need justifies that deployment
boundary. Preserve the existing reducer, permits, effect registry, and engine lifetime rules while
separating their owner from presentation.

## Decision

| Owner | Responsibility |
| --- | --- |
| [`SpottySessionRuntime`](../../../Sources/SpottySessionRuntime) | Account lifecycle, writable playback state, commands, queue precedence, recovery, termination |
| [`SpottyRuntimeContracts`](../../../Sources/SpottyRuntimeContracts) | Typed, Sendable catalog/session values and platform capabilities shared across modules |
| [`SpottyGateway`](../../../Sources/SpottyGateway) | Authorization, private wire models, transports, response mapping, operation-specific failures |
| [`SpottyEngineAdapter`](../../../Sources/SpottyEngineAdapter) | Sole production consumer of the playback binary, C snapshots, and audio renderer |
| [`PlaybackStore`](../../../Sources/Spotty/Spotify/PlaybackStore.swift) | MainActor presentation adapter applying equatable publications and forwarding user actions |

The session actor has a dedicated serial executor. Transitions commit bounded in-memory state;
network, storage, and blocking engine work use separate workers. Every continuation revalidates
its captured lifetime. Actor isolation alone cannot make an old account, engine, route, or command
current. The runtime constructs no SwiftUI or AppKit presentation objects.

[`PlaybackTransitions`](../../../Sources/SpottySessionRuntime/PlaybackTransitions.swift) owns reducer
state and queued dispatch permits together. A transition collects claim receipts, reduces the event,
and invalidates obsolete permits. Each permit names one admitted intent. Receipts publish independently
of event acceptance; duplicate or already-dispatched intents cannot acquire another capability.
Disposal revokes unclaimed permits.
Accepted reducer state owns engine generation; teardown commits its reset before canceling effects.
Explicit task ownership remains with `PlaybackEffectRegistry`; there is no general effect framework.

One lifecycle owner admits work and coalesces account retirement and termination. Every termination
caller joins the same cleanup, including logout already underway; retirement completing during
termination never reopens admission. Preference persistence has one worker retaining only the latest
pending value per key. A preference-state owner admits saved scalars only until newer activity
supersedes them, and merges new plays with saved history before writing a replacement dictionary.
Account replacement abandons old reads and queued values, but an entered write settles before clears.
Normal quit joins accepted history merging and persistence under its existing deadline.

The desktop's stamped entrance and runtime publications form one command/state path. Its synchronous
admission work is bounded and never waits for network, storage, MainActor, or blocking FFI operations.
Headless tests use those same runtime methods with injected workers. A parallel RPC namespace,
receipt ledger, or serialized session protocol needs a concrete shipping client.

Catalog readiness publishes account, availability, and revision, advancing revision even across
coalesced transitions. The desktop preserves that identity, owns browsing loads, and cancels them on
session change; the runtime never awaits desktop browsing. Immutable entity snapshots enrich retained
playback labels without carrying collection membership. They carry account and source revision;
stale input is rejected. Playback publications never become browsing input. Views consume prepared
publications, not the reducer snapshot.

Catalog and metadata attempts share bounded admission, prioritizing interactive reads over queued
enrichment. Playback commands have their own lane. Read retries remain distinct from uncertain writes.
Feature stores receive domain snapshots, never wire models. Gateway module privacy does not make
Spotify's private interfaces stable or supported.

Playlist requests and authorized writes use separate ports. One catalog-session owner supplies both
the published identity and live write fence. Rendered stamps must match to authorize dispatch;
reconnect invalidates old validation even for the same account. Every client, including factory-supplied
clients, rechecks authorization at wire attempts and after capacity waits. Editing requires current
profile and collection proof; retained ownership cannot authorize it. No context-dropping fallback exists.

Queue ordering uses the domain's `QueueEntry` occurrence identity. Metadata merging cannot borrow a
UID from the same song or an older position. UI disambiguation retains supplied UIDs.
`QueueService` derives display rows and mutation provenance from one decoded Connect observation,
including its revision and generation. Provisional input can preserve complete display ordering while
withdrawing mutation authority; callers cannot supply the two representations independently.
PCM stays inside the engine adapter and its renderer.
Closing a window keeps the in-process runtime alive; quitting terminates it. This provides no playback
after app termination or crash. Catalog retention follows [ADR 009](ADR-009-account-catalog-retention.md).

## Tradeoffs and alternatives

This separates authority and scheduling without process containment. A stalled transition can still
delay synchronous admission, so bounded work is a correctness requirement. Revisit a separate helper
only for a measured reliability or user need; repository history retains the removed XPC prototype.

OAuth persistence follows [ADR 007](ADR-007-session-persistence.md). Keychain adoption would require
verified signing continuity and a recoverable migration; this decision does not migrate grants.
