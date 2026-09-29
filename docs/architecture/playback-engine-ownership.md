# Playback engine ownership

[ADR 005](adrs/ADR-005-retain-librespot.md) keeps private protocol and runtime work in the retained
Rust/librespot engine. Swift owns application policy and presentation; AVFoundation renders its
PCM output.

## Swift (authoritative app state)

| Responsibility | Owner |
| --- | --- |
| Account connection lifecycle and its single writable epoch | [AccountStore](../../Sources/SpottySessionRuntime/AccountStore.swift) on the session executor |
| Session admission, teardown coalescing, and termination completion | [SessionLifecycle](../../Sources/SpottySessionRuntime/SessionLifecycle.swift), with cleanup orchestrated by `PlaybackSessionRuntime` |
| Atomic playback presentation and stale-observation rejection | [PlaybackState](../../Sources/SpottyDomain/PlaybackState.swift) and its reducer |
| Command serialization, cancellation, and follow-ups | [ADR 003](adrs/ADR-003-playback-command-effects.md) |
| Queue precedence, playback context, and mutation authority | [QueueService](../../Sources/SpottySessionRuntime/QueueService.swift) |
| Pure queue/device/connection/playback projections and resume target order | [SpottyDomain](../../Sources/SpottyDomain) |
| Private Spotify wire models, authorization, HTTP retry, and failure mapping | [SpottyGateway](../../Sources/SpottyGateway), consumed through typed runtime contracts |
| Catalog session identity and playlist dispatch admission | [CatalogSessionAdmission](../../Sources/SpottyRuntimeContracts/PlaylistMutationContext.swift), updated by `AccountStore` and projected by the runtime |
| Account-admitted persistent browsing data | [Catalog retention](adrs/ADR-009-account-catalog-retention.md) |
| MainActor observation, native commands, and browsing presentation | [PlaybackStore](../../Sources/Spotty/Spotify/PlaybackStore.swift) and [native surface ownership](adrs/ADR-010-native-dense-surfaces.md) |
| Output buffering, backpressure, routes, and audio teardown | [AudioRenderer](../../Sources/SpottyEngineAdapter/AudioRenderer.swift), with complete-frame storage in [StereoPCMBuffer](../../Sources/SpottyEngineAdapter/StereoPCMBuffer.swift) |
| The C boundary, typed engine observations, and their fan-out | [SpottyEngineAdapter](../../Sources/SpottyEngineAdapter), the only production target directly depending on the playback binary |

PCM buffering preserves complete stereo frames and rejects malformed packets. Each callback owns
one bounded wait; buffer resets cannot replenish it. The renderer retains synchronization, pacing,
and Core Media ownership.
The runtime prepares audio through `LiveAudioOutput`; renderer implementation stays internal.

Account epoch projections share one counter. Connect callback identity stays separate from merged
queue presentation; adopting an engine epoch preserves its watermark. Metadata enriches labels
without replacing occurrence order or mutation authority.

QueueService owns queue authority; its refresh worker owns Web, metadata, timer, and callback
waits. Panel cancellation removes a subscriber, preserving hydration. Discarding the service
cancels its worker without awaiting dependencies. Publications recheck account/context, flight, and
subscriber identity; enrichment follows Connect ordering.

TrackMetadataService shares fetches and a bounded account cache across hydration and Now Playing,
independently of blocking engine commands. Caller cancellation settles its waiter; the last caller
retires the fetch. Reset clears the cache and cancels every unresolved waiter. Late responses cannot
affect replacements; callers still validate their captured account and engine lifetime.

An engine delivery overflow resets intent history while retaining QueueService's ordered facts
and metadata work. Process-monotonic Rust source revisions still decide queue precedence: getters
may be newer than replayed callbacks. Equal or older replays preserve the actor's accepted queue
and watermark. Canceled subscribers cannot publish; continuing hydration enriches the latest
accepted Connect order.

## Rust (protocol and engine lifetimes)

[GenerationResources](../../Backend/spotty-playback/src/engine_resources.rs) carries protected
ownership through construction, atomic publication, and retirement. Spirc has a named task;
listener registration adopts or drains each task. Extraction precedes callbacks, joins, and object
destruction outside the engine mutex. Cancellation retains task abort and Session invalidation.

Spirc owns ordinary local Player mutations: play, pause, load, seek and transfer-to-local.
Remote handoff uses the session's SpClient transfer request; its local pause goes through Spirc.
Construction hands Spirc the mutable Player; published generations and the adapter event pump hold `PlayerObserver`,
which exposes subscription and lifetime retention only. Shutdown goes through Spirc; bounded abort and Player drop remain fallbacks. Loads require captured modes and an
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

`Scripts/check-transport-traces.sh` times offline Spirc/adapter traces with synthetic identities,
no credentials, connection, or audio. The Rust gate includes them. Pair them with the Demo for visible
controls, since a single synthetic authority cannot prove the real two-consumer ordering.

Rust supplies bounded PCM and typed protocol observations through the
[C boundary](../../Sources/SpottyPlaybackCore/include/spotty_playback.h). The checked-in header is
producer-canonical; the app compiles the pinned XCFramework's copy. Rust retains sticky resume
identity, while Swift selects targets. Readiness stays
held until reconnect rehydration finishes; do not create a second protocol state machine across
that boundary.

See [engine contracts](engine-contract.md) for lifetime and FFI semantics,
[product contracts](../product/README.md) for behavior, and [enforcement](enforcement.md) for verification.

### Connect observations

Keep the bridge's hidden observer and cluster subscription on the existing session's Dealer.
[Spirc](../../Backend/spotty-playback/vendor/librespot/connect/src/spirc.rs) owns the real playback
device, incoming commands, transfers, and state publication. Its public handle exposes commands,
not a stream of complete clusters. It consumes the registration response internally; player
events do not expose the complete initial device roster or a remote player's queue.

The bridge's [initial cluster fetch](../../Backend/spotty-playback/src/connect.rs) registers a
hidden, non-player member for the initial snapshot. Its distinct ID prevents partial observer state
from replacing Spirc's playback-device registration. Later pushes use the same mapping. Both
subscriptions share one Dealer connection; the bridge observes account state while Spirc acts.

Forwarding Spirc's registration reply and pushes could remove the separate bootstrap, but requires
a retained upstream API change with delivery, buffering, ordering, and teardown guarantees. Keep
the existing observation boundary until a compatible upstream interface or measured benefit
justifies that maintenance. Preserve the bootstrap/push precedence and account-generation fences
in the [engine contract](engine-contract.md); apparent subscription duplication is not sufficient
reason to remove them.
