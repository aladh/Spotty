# Deterministic behavior enforcement

[Enforcement inventory](../enforcement.md)

## Deterministic behavior

Use these families to find the relevant evidence. Individual cases and assertions belong in the
[domain tests](../../../Tests/SpottyDomainTests), [boundary tests](../../../Tests/SpottyBoundaryTests),
and [Rust suite](../../../Backend/spotty-playback/src). Passing a suite does not prove untested
lifetime or ordering behavior.

| Behavior to protect | Contract |
| --- | --- |
| Atomic presentation and a single mutation owner | [ADR 002](../adrs/ADR-002-playback-state-and-dependencies.md) |
| Command acceptance, cancellation, reconciliation, and rollback | [ADR 003](../adrs/ADR-003-playback-command-effects.md) |
| Generations, stale work, ordered delivery, and transactional engine lifetimes | [Engine contracts](../engine-contract.md) |
| Panic containment, callback ownership, and bounded PCM delivery | [Engine boundary](../../../Backend/spotty-playback/AGENTS.md) |
| Typed protocol intake and Swift-owned queue/device/connection/playback projections | [Engine ownership](../playback-engine-ownership.md) |
| Resume target policy and reconnect readiness | [Engine contracts](../engine-contract.md) |
| Occurrence-safe playlist writes and lifetime-safe transient feedback | [Playlists](../../product/playlists.md), [feedback](../../product/navigation.md#transient-mutation-feedback) |
| Injected production boundaries | [ADR 002](../adrs/ADR-002-playback-state-and-dependencies.md) |
| Synthetic, non-identifying fixtures | [Privacy](../../../PRIVACY.md) |
| Retained protocol, recovery, and ABI behavior | [Engine boundary](../../../Backend/spotty-playback/AGENTS.md) |
| Complete test discovery and bounded repeat execution | [Test guidance](../../../Tests/AGENTS.md), [verification](../../development/verification.md) |
