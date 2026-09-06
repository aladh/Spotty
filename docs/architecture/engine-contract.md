# Playback engine contracts

[Engine ownership](playback-engine-ownership.md) · [Enforcement inventory](enforcement.md)

## Retained-engine guarantees

- Initialization is transactional: resources and listener tasks remain staged until the whole
  generation is ready. Failed or superseded construction rolls back and joins staged work.
  Teardown invalidates the generation and drains work, giving Spirc a bounded opportunity to finish
  gracefully before forced shutdown. The old Dealer connection closes before replacement.
  A failed activation cannot publish readiness.
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
- Playback observations include their active-device fact. Swift must not infer ownership from
  callback arrival order. Account/engine lifetimes and source revisions reject stale observations.

## FFI surface

The [generated declarations](../../Sources/SpottyPlaybackCore/include/spotty_playback_generated.h)
and [Swift annotations](../../Sources/SpottyPlaybackCore/include/spotty_playback_annotations.h)
own field layouts, signatures, nullability, and allocation contracts. Connection, playback,
devices, and queue cross as typed protocol snapshots, not raw protobuf or presentation copy.

Preserve these distinctions when changing the boundary:

- Missing and interior-NUL strings normalize before callback delivery. Empty strings normally mean
  absent, but playback context uses null for no update and empty for an explicit clear.
- Local timing observations omit context. Sticky context is for resume getters only, not a second
  source of ordinary playback presentation.
- Track-unavailable is a one-observation indication of a failed current local load. Rust filters
  request identity and preload failures; Swift owns lifetime/optimistic-target gating and the
  [user-facing notice](../product/playback.md#transport-and-progress).
- A null cached queue snapshot means no cluster observation has arrived, not an empty queue. That
  cache can recover from a provisional empty replacement but is not another app-facing store.

## Standing constraints

Keep PCM, sessions, Spirc, streaming, decryption, and decoding in the retained engine under
[ADR 005](adrs/ADR-005-retain-librespot.md). Swift owns resume target order; do not widen the legacy
resume export or use presentation snapshots as resume identity. Reconnect backoff stays local to
its loop; connection presentation must not acquire duplicate device-name, retry-counter, timestamp,
or session-identity state. New protocol or ownership boundaries require an explicit architectural
decision, not another engine or state machine alongside the existing one.
