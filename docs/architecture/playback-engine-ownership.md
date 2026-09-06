# Playback engine ownership

[ADR 005](adrs/ADR-005-retain-librespot.md) keeps private protocol and runtime work in the retained
Rust/librespot engine. Swift owns application policy and presentation; AVFoundation renders its
PCM output. This page describes boundaries, not a module inventory.

## Swift (authoritative app state)

| Responsibility | Owner |
| --- | --- |
| Account lifecycle and its single writable epoch | [AccountStore](../../Sources/Spotty/Spotify/AccountStore.swift) |
| Atomic playback presentation and stale-observation rejection | [PlaybackState](../../Sources/SpottyDomain/PlaybackState.swift) and its reducer |
| Command serialization, cancellation, and follow-ups | [ADR 003](adrs/ADR-003-playback-command-effects.md) |
| Queue precedence, playback context, and mutation authority | [QueueService](../../Sources/Spotty/Spotify/QueueService.swift) |
| Pure queue/device/connection/playback projections and resume target order | [SpottyDomain](../../Sources/SpottyDomain) |
| Catalog, authorization, HTTP retry, and user-facing errors | [Spotify adapters](../../Sources/Spotty/Spotify) |
| Output buffering, backpressure, routes, and audio teardown | [AudioRenderer](../../Sources/Spotty/Spotify/AudioRenderer.swift) |

Account epoch projections are not independent counters. Connect callback identity must also remain
separate from merged queue presentation: adopting an engine epoch must not erase the callback
watermark. Metadata can enrich authoritative queue labels, never replace its occurrence order or
mutation authority.

## Rust (protocol and engine lifetimes)

The [Rust leaf](../../Backend/spotty-playback/src) owns sessions, Spirc/Connect, streaming,
decryption, decoding, the streaming credential cache, and coordination tied to those lifetimes.
Construction and teardown must publish or discard an engine generation atomically. Cluster
arbitration and active-device facts remain protocol work; display sorting and transport presentation
do not belong here.

Rust supplies bounded PCM and typed protocol observations through the
[C boundary](../../Sources/SpottyPlaybackCore/include/spotty_playback.h). It retains sticky resume
identity, while Swift selects resume targets. Readiness stays held until reconnect rehydration
finishes; do not create a second protocol state machine across that boundary.

See [engine contracts](engine-contract.md) for non-obvious lifetime and FFI semantics,
[product contracts](../product/README.md) for observable behavior, and the
[enforcement inventory](enforcement.md) for verification owners.
