# Playback engine ownership

[ADR 005](adrs/ADR-005-retain-librespot.md) keeps private protocol and runtime work in the retained
Rust/librespot engine. Swift owns application policy and presentation; AVFoundation renders its
PCM output. This page describes boundaries, not a module inventory.

## Swift (authoritative app state)

| Responsibility | Owner |
| --- | --- |
| Account connection lifecycle and its single writable epoch | [AccountStore](../../Sources/SpottySessionRuntime/AccountStore.swift) on the session executor |
| Session teardown coalescing, ordering, and gate release | [SessionTeardownController](../../Sources/SpottySessionRuntime/SessionTeardownController.swift), owned by `PlaybackSessionRuntime` |
| Atomic playback presentation and stale-observation rejection | [PlaybackState](../../Sources/SpottyDomain/PlaybackState.swift) and its reducer |
| Command serialization, cancellation, and follow-ups | [ADR 003](adrs/ADR-003-playback-command-effects.md) |
| Queue precedence, playback context, and mutation authority | [QueueService](../../Sources/SpottySessionRuntime/QueueService.swift) |
| Pure queue/device/connection/playback projections and resume target order | [SpottyDomain](../../Sources/SpottyDomain) |
| Private Spotify wire models, authorization, HTTP retry, and failure mapping | [SpottyGateway](../../Sources/SpottyGateway), consumed through typed runtime contracts |
| Account-admitted persistent browsing data | [Catalog retention](adrs/ADR-009-account-catalog-retention.md) |
| MainActor observation, native commands, and browsing presentation | [PlaybackStore](../../Sources/Spotty/Spotify/PlaybackStore.swift) and [native surface ownership](adrs/ADR-010-native-dense-surfaces.md) |
| Output buffering, backpressure, routes, and audio teardown | [AudioRenderer](../../Sources/SpottyEngineAdapter/AudioRenderer.swift) |
| The C boundary, typed engine observations, and their fan-out | [SpottyEngineAdapter](../../Sources/SpottyEngineAdapter), the only production target directly depending on the playback binary |

[ADR 008](adrs/ADR-008-headless-session-runtime.md) places session authority on its dedicated
transition executor. The production client and runtime both execute inside the app process.

Account epoch projections are not independent counters. Connect callback identity must also remain
separate from merged queue presentation: adopting an engine epoch must not erase the callback
watermark. Metadata can enrich authoritative queue labels, never replace its occurrence order or
mutation authority.

Queue refresh and metadata hydration share an account/context flight owned by QueueService.
Canceling a panel consumer removes its updates without discarding useful shared work; account or
context replacement cancels the flight. New Connect ordering can extend enrichment while keeping
its occurrence order authoritative. Subscriber cancellation and lifetime checks apply again at
publication, including after a Web failure.

An engine delivery overflow resets store intent history while retaining QueueService's ordered
facts and metadata work. Process-monotonic Rust source revisions still decide queue precedence:
a newer getter observation may already exceed the replayed callback. An equal or older replay
therefore uses the actor's accepted queue rather than rolling its watermark back. Canceled
subscribers cannot publish, and continuing hydration enriches the latest accepted Connect order.

## Rust (protocol and engine lifetimes)

The [Rust leaf](../../Backend/spotty-playback/src) owns sessions, Spirc/Connect, streaming,
decryption, decoding, the streaming credential cache, and coordination tied to those lifetimes.
Construction and teardown must publish or discard an engine generation atomically. Cluster
arbitration and active-device facts remain protocol work; display sorting and transport presentation
do not belong here.

Spirc owns ordinary local Player mutations: play, pause, load, seek and transfer-to-local.
Remote handoff uses the session's SpClient transfer request; its local pause goes through Spirc.
Construction hands Spirc the mutable Player; published generations and the adapter event pump hold `PlayerObserver`,
which exposes subscription and lifetime retention only. Shutdown also goes through Spirc, with
bounded task abort and Player drop as lifecycle fallbacks. Loads require captured modes and an
explicit context/supplied-order policy before activation; recovery uses that same boundary.

### Event admissibility

These dimensions are independent; arrival order across the two consumers establishes no command
ordering. The retained handler owns desired transport, while the adapter owns observed evidence.

| Event/evidence | Admission and effect |
| --- | --- |
| Replaced engine generation | Inert, including terminal events; only its own tasks may drain. |
| Old load request | Inert for transport, position and resume evidence. |
| Current Playing/Paused against newer opposite intent | Spirc preserves desired transport until the matching event. Adapter samples alone cannot confirm protocol playback. |
| Deactivation | Save nonzero resume position and disarm load failure notices; retain current request identity. |
| Current Stopped/EndOfTrack after deactivation | Release live position and local loaded-track evidence without erasing the saved resume position. |
| Command dispatch/acknowledgement | Admission evidence only. Resume/recovery confirmation requires fresh matching generation, track/context, position and local/protocol ownership evidence within the existing bounded wait. |

The manual timing helper `Scripts/check-transport-traces.sh` runs the named offline Spirc/adapter traces and reports source,
engine identity and runtime. They use synthetic identities and no credentials,
connection or audio output; the normal Rust gate includes them. Pair them with the Demo for visible
controls, since a single synthetic authority cannot prove the real two-consumer ordering.

Rust supplies bounded PCM and typed protocol observations through the
[C boundary](../../Sources/SpottyPlaybackCore/include/spotty_playback.h). The checked-in header is
producer-canonical; the app compiles the pinned XCFramework's copy. Rust retains sticky resume
identity, while Swift selects targets. Readiness stays
held until reconnect rehydration finishes; do not create a second protocol state machine across
that boundary.

See [engine contracts](engine-contract.md) for non-obvious lifetime and FFI semantics,
[product contracts](../product/README.md) for observable behavior, and the
[enforcement inventory](enforcement.md) for verification owners.

### Connect observations

Keep the bridge's hidden observer and cluster subscription on the existing session's Dealer.
[Spirc](../../Backend/spotty-playback/vendor/librespot/connect/src/spirc.rs) owns the real playback
device, incoming commands, transfers, and state publication. Its public handle exposes commands,
not a stream of complete clusters. It consumes the registration response internally; player
events do not expose the complete initial device roster or a remote player's queue.

The bridge's [initial cluster fetch](../../Backend/spotty-playback/src/connect.rs) registers a
hidden, non-player member to obtain that snapshot without waiting for another device to change.
It uses a distinct member ID because replacing Spirc's registration with a partial observer state
would alter the playback device. Subsequent pushes feed the same bridge mapping for devices,
ownership, playback, and queue. Both subscriptions share one Dealer connection; the bridge
observes account state while Spirc acts on protocol state.

Forwarding Spirc's registration reply and pushes could remove the separate bootstrap, but requires
a retained upstream API change with delivery, buffering, ordering, and teardown guarantees. Keep
the existing observation boundary until a compatible upstream interface or measured benefit
justifies that maintenance. Preserve the bootstrap/push precedence and account-generation fences
in the [engine contract](engine-contract.md); apparent subscription duplication is not sufficient
reason to remove them.
