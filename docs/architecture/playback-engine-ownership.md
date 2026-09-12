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

Rust supplies bounded PCM and typed protocol observations through the
[C boundary](../../Sources/SpottyPlaybackCore/include/spotty_playback.h). That checked-in header is
the producer-canonical copy; the app actually compiles against the copy shipped inside the pinned
XCFramework. It retains sticky resume identity, while Swift selects resume targets. Readiness stays
held until reconnect rehydration finishes; do not create a second protocol state machine across
that boundary.

See [engine contracts](engine-contract.md) for non-obvious lifetime and FFI semantics,
[product contracts](../product/README.md) for observable behavior, and the
[enforcement inventory](enforcement.md) for verification owners.
