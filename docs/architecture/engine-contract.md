# Playback engine contracts

[Engine ownership](playback-engine-ownership.md) · [Enforcement inventory](enforcement.md)

## Retained-engine guarantees

- Initialization is transactional: resources and listener tasks remain staged until the whole
  generation is ready. Failed or superseded construction rolls back and joins staged work.
  Teardown invalidates the generation and drains work, giving Spirc a bounded opportunity to finish
  gracefully before forced shutdown. The old Dealer connection closes before replacement.
  A failed activation cannot publish readiness.
- Recovery triggers share one Rust-owned lease. A lease captures the triggering generation;
  wake, stream closure, command failure and health detection coalesce while it is active.
  Sleep, shutdown, cleanup and an explicit replacement retire that lease. Retirement wakes
  backoff immediately and fences readiness/credential feedback from construction already in
  flight; construction still settles transactionally under the lifecycle mutex. A retired
  task cannot clear its replacement's ownership. Transient outages retry indefinitely with
  delays of 0, 2, 5, 10, then 30 seconds; credential rejection terminates the owning run.
  Diagnostics report one named terminal outcome, monotonic trigger-to-settlement time, and attempt
  count per lease, without account/device identifiers or a network-latency guarantee. Silent-session
  detection runs every 60 seconds. Swift owns account admission and child-work drain, not engine retries.
- Each AP attempt bounds socket/proxy setup plus handshake at five seconds; see the retained
  [connection patch](../../Backend/spotty-playback/vendor/librespot/core/src/connection/mod.rs) and
  [patch record](../../Backend/spotty-playback/vendor/librespot/README.md). Retry count, authentication,
  token fetching, and total initialization have separate budgets. Timeouts are transient and retain credentials.
- Swift supplies a validated, opaque installation identity before authorization or playback
  sessions begin. The engine copies it once and rejects a conflicting process-lifetime value.
  Authorization and playback share this identity: the authorization session obtains reusable
  AP credentials and is shut down before the playback session starts under the lifecycle lock.
  Logout removes credentials but retains this non-secret identity, separate from computer name and client-token identity.
  [ConnectInstallationIDStore](../../Sources/SpottyEngineAdapter/ConnectInstallationIDStore.swift)
  supplies it; [local state](../development/local-state.md) defines Debug/test isolation.
- Closed command channels and failed rehydration request engine reinitialization through typed
  outcomes. Rehydrate before announcing readiness; fetching Web playback state afterward would
  reopen the stale-position window.
- Definitive streaming-credential rejection clears only the current generation's streaming cache
  and crosses the boundary as a typed rejection snapshot and initialization result. Swift stops
  launch restore with that credential, preserves the independent Keymaster grant, and persists the
  need for reauthorization; a fresh durably adopted grant clears that requirement. Refresh-revoked grants
  are cleared only for their owning account generation. The adapter must distinguish definitive
  rejection from general permission failures; its comparison against private upstream errors
  requires review on librespot updates.
- Playback observations carry ownership; callback order cannot establish it. Account/engine
  lifetimes, source revisions, and local load IDs fence stale events, including position samples.

## FFI surface

The checked-in [declarations](../../Sources/SpottyPlaybackCore/include/spotty_playback_generated.h)
and [annotations](../../Sources/SpottyPlaybackCore/include/spotty_playback_annotations.h) own producer
layouts, signatures, nullability, and allocation contracts. The app compiles against headers in
[Package.swift](../../Package.swift)'s pinned XCFramework; [check.sh](../../Scripts/check.sh) validates that copy.
Connection, playback, devices, and queue cross as typed protocol snapshots, not raw protobuf or
presentation copy.

The aggregate Connect-cluster callback carries local identity, devices, connection, and optional
playback/queue facts under one generation/revision, with explicit bootstrap/dealer-push provenance.
Registration replaces cluster-origin legacy notifications only; player-local and lifecycle callbacks
remain separate ordered sources. Copy borrowed nested pointers before returning. Snapshot capture
holds the revision lock; callback delivery does not. Update canonical queue/playback caches before
delivery so reentrant getters see published facts and reentrant cleanup cannot precede a stale write.

Preserve these distinctions when changing the boundary:

- Missing and interior-NUL strings normalize before callback delivery. Empty strings normally mean
  absent, but playback context uses null for no update and empty for an explicit clear.
- Local timing observations omit context. Sticky context is for resume getters only, not a second
  source of ordinary playback presentation.
- Track-unavailable is a one-observation indication of a failed current local load. Rust filters
  request identity and preload failures; Swift owns lifetime/optimistic-target gating and the
  [user-facing notice](../product/playback.md#transport-and-progress). The accompanying audio-key-refused
  bit distinguishes explicit key refusal followed by decoder failure. This stops the current
  player and sink without advancing or marking queue occurrences unavailable. Refused preloads
  neither stop the current track nor mark the upcoming occurrence unavailable. An unencrypted
  playable file is accepted; transient key errors do not acquire this classification.
- A null cached queue snapshot means no cluster observation has arrived, not an empty queue. That
  cache can recover from a provisional empty replacement but is not another app-facing store.
- Observed user resume carries the displayed track, context, paused position, and engine generation
  as an expectation. An idle join validates against ordered protocol observations; an active local
  player uses its loaded track and current position with track-scoped protocol context. An idle
  local join restores the Connect session paused, then requires completed queue restoration,
  protocol ownership, and matching local player evidence before sending Play. Provisional
  samples wait within the restoration deadline for agreement. It preserves the
  observed queue occurrences and options even when the resolved playlist has changed; it never
  loads a playlist or another track as a fallback. Changed or unavailable evidence returns the
  resume-mismatch result. Concurrent resumes return a separate retryable busy result. Restoration
  and Playing confirmation have separate five- and two-second budgets. Success requires a fresh
  protocol observation naming this device and the expected playing track/context/position as well
  as a new local Playing event. A failed confirmation pauses the same local track if this generation
  still owns it. Local timing samples and a successful command return alone cannot confirm a resume
  or advance its presentation. Legacy resume and sticky load targets remain available for reconnect
  rehydration until consumers adopt the observed-resume entry point.

## Standing constraints

Keep PCM, sessions, Spirc, streaming, decryption, and decoding in the retained engine under
[ADR 005](adrs/ADR-005-retain-librespot.md). Swift owns resume target order; do not widen the legacy
resume export. User resume expectations must be checked against engine observations, never treated
as proof that the local player has loaded the displayed track. Reconnect backoff stays local to
its loop; connection presentation must not acquire duplicate device-name, retry-counter, timestamp,
or session-identity state. New protocol or ownership boundaries require an architectural decision,
not a parallel engine or state machine.
