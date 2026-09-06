# Playback engine ownership

Current responsibilities for the retained engine in [ADR 005](adrs/ADR-005-retain-librespot.md).
Private protocol/runtime work stays in `Backend/spotty-playback`; Swift owns application policy and
presentation. Rust also retains coordination tied to its object lifetimes and streaming cache.

Product behavior belongs in the [product and acceptance
contract](../product/README.md); hard-rule owners belong in the [enforcement
inventory](enforcement.md).

## Swift (authoritative app state)

| Owner | Responsibility |
| --- | --- |
| `AccountStore` | Owns account lifecycle and the only writable account epoch, `AccountStore.epoch`. `PlaybackStore.accountEpoch` is a read-only projection; `PlaybackState.accountEpoch` is reducer-accepted snapshot state, not another lifecycle counter. |
| `PlaybackState` / `PlaybackReducer` | Atomic presentation snapshot; stale/revision/epoch rejection |
| `PlaybackStore` / `PlaybackCoordinator` / `PlaybackEffectRegistry` | MainActor actions, serialized effects, task lifetimes |
| `QueueService` | Owns source precedence, context identity, and the Connect mutation snapshot. Same-context Web `/me/player/queue` results may enrich labels only; they cannot replace authoritative Connect occurrence order or its `revision` / `receivedAt`. `PlaybackStore.queueMutation` projects that authority for the app; it is not a second mutation source. |
| `PlaybackStore.connectQueueCallback` / `ConnectQueueCallbackWatermark` | Owns Connect callback generation/revision identity separately from merged queue state. Adopting an engine epoch does not clear that watermark. |
| `QueueProtocolProjection` | Upcoming-rail rows from protocol `next` tracks; occurrence removal |
| `ConnectDeviceProjection` | Device-list activity, display sort, empty-type fallback |
| `ConnectionSnapshotProjection` | Connection session phase, empty-device-id fallback |
| `PlaybackSnapshotProjection` | Engine playback transport, empty-URI identity, timestamp correction |
| `ResumeLoadPlan` | Target order from sticky resume-load URIs for user resume and reconnect rehydration. `PlaybackStore` captures the URIs through engine getters; `RustPlaybackEngine` loads each target. During reconnect, the engine holds readiness behind `resume_pending` until a Swift load lands, reports `ERROR_NEEDS_REINIT`, or times out. |
| Catalog, OAuth, shuffle policy, HTTP retry | Application policy owned by Swift; these responsibilities do not belong in the engine |
| `AudioRenderer` | Native AVFoundation output for the bounded PCM callback from the retained Rust/librespot player; owns output buffering, backpressure, route changes, and renderer teardown |

## Rust crate by module

| Module | Classification | Notes |
| --- | --- | --- |
| `ffi.rs`, `runtime.rs` | Protocol/runtime adapter | Panic barrier, C string delivery, nested-runtime refusal |
| `proxy_sink.rs` | Protocol/runtime adapter | Librespot's decoded PCM to the bounded Swift audio callback; no UI state crosses this path |
| `session_lifecycle.rs` | Adapter | Serialized authorization, initialization exports, health checks, and reconnect orchestration. |
| `session_construction.rs` | Adapter | Transactional session/player/Spirc construction, publication, and rollback guards. Player configuration is fixed at 320 kbps and gapless; Connect registers at full volume while Swift owns output volume. |
| `engine_resources.rs` | Adapter | Shared resource extraction, graceful task shutdown, and cancellation-safe cleanup. |
| `credentials_cache.rs` | App policy | Streaming cache path selection, retired-directory cleanup, and logout cache clearing. |
| `lifecycle_serialization.rs` | Spotty-owned coordination that must stay with Rust globals | One async lifecycle mutex, reconnect unit outcomes, generation revalidation |
| `connect.rs` | Mixed | Dealer subscribe, hidden-member bootstrap PUT, and protobuf parse are protocol. Device-list and connection-snapshot presentation are Swift-owned. `cluster_offer_decision`, bootstrap-vs-push linearization, and `is_active_in_cluster` (this engine's Connect role) remain Rust-owned Connect logic. |
| `queue.rs` | Adapter | Forwards unfiltered `ProvidedTrack` rows and slim current-track identity as `SpottyQueueSnapshot`. Cluster protocol playback flags and authoritative context cross as `SpottyPlaybackSnapshot`; local timing events omit context, while sticky context remains confined to the resume getter. Does **not** own delimiter hiding, upcoming presentation, or transport presentation. |
| `state.rs` | Mixed | Librespot object slots (`SESSION`, `SPIRC`, `PLAYER`, `MIXER`). Snapshot stamps and connection aggregation live here. Queue, connection, playback, and device-list observations use typed C snapshots. |
| `transport.rs` | Adapter | Seek-capable `load_at_position`, one-target `LoadRequest` construction, playing-event waits, and the reconnect rehydration window (`has_resume_identity`, `wait_for_rehydration`). Target order and capture are Swift-owned for user resume and reconnect alike. |
| `player_control.rs` | Adapter | Spirc play/pause/seek/shuffle/repeat/transfer/queue-add, plus FFI getters for sticky resume URIs |
| `player_event_pump.rs` | Adapter | Local `PlayerEvent` → position and protocol playing/paused bits when this device is active |
| `spirc_command_error.rs` | Adapter | Map librespot errors onto FFI codes Swift already understands |
| `librespot-connect` | Protocol/runtime dependency | The pinned upstream Connect implementation remains the engine's Connect owner; updates require protocol and license review |

## Related contracts

- [Engine contracts](engine-contract.md): lifecycle guarantees, typed FFI snapshots, and standing constraints.
- [Performance baseline](performance-baseline.md): historical CPU, memory, and binary-size reporting.
