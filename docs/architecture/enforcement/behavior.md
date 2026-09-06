# Deterministic behavior enforcement

[Enforcement inventory](../enforcement.md)

## Deterministic behavior

Use these families to find the relevant evidence. Individual cases and assertions belong in the
[domain tests](../../../Tests/SpottyDomainTests), [boundary tests](../../../Tests/SpottyBoundaryTests),
and [Rust suite](../../../Backend/spotty-playback/src). Passing a suite does not prove untested
lifetime or ordering behavior.

| IDs | Behavior to protect | Contract |
| --- | --- | --- |
| `TST-STATE-001` | Atomic presentation and a single mutation owner | [ADR 002](../adrs/ADR-002-playback-state-and-dependencies.md) |
| `TST-CMD-001` | Command acceptance, cancellation, reconciliation, and rollback | [ADR 003](../adrs/ADR-003-playback-command-effects.md) |
| `TST-EPC-001`, `TST-ENV-001`, `TST-LIF-001` | Generations, stale work, ordered delivery, and transactional engine lifetimes | [Engine contracts](../engine-contract.md) |
| `TST-FFI-001`, `TST-PCM-001` | Panic containment, callback ownership, and bounded PCM delivery | [Engine boundary](../../../Backend/spotty-playback/AGENTS.md) |
| `TST-QUE-001`, `TST-DEV-001`, `TST-CON-001`, `TST-PBK-001` | Typed protocol intake and Swift-owned queue/device/connection/playback projections | [Engine ownership](../playback-engine-ownership.md) |
| `TST-RES-001` | Resume target policy and reconnect readiness | [Engine contracts](../engine-contract.md) |
| `TST-PLM-001`, `TST-FBK-001` | Occurrence-safe playlist writes and lifetime-safe transient feedback | [Playlists](../../product/playlists.md), [feedback](../../product/navigation.md#transient-mutation-feedback) |
| `TST-DEP-001` | Injected production boundaries | [ADR 002](../adrs/ADR-002-playback-state-and-dependencies.md) |
| `TST-FIX-001` | Synthetic, non-identifying fixtures | [Privacy](../../../PRIVACY.md) |
| `TST-RUST-001` | Retained protocol, recovery, and ABI behavior | [Rust guidance](../../../Backend/spotty-playback/AGENTS.md) |
| `TST-GATE-001` | Complete test discovery and bounded repeat execution | [Test guidance](../../../Tests/AGENTS.md), [verification](../../development/verification.md) |
