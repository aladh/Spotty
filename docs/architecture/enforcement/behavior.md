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

## Reducer model check

`PlaybackReducer` is additionally covered by a seeded model (property) check in
[`PlaybackReducerModelChecks`](../../../Tests/SpottyDomainTests/PlaybackReducerModelChecks.swift).
It replays randomized envelope traces over a small universe of tracks, devices, epochs, and
per-source revisions, covering every `PlaybackEvent` case, and validates each step — accepted or
rejected — against invariants rather than expected outputs: rejection is inert; the account epoch
never regresses and the engine epoch never regresses within an account; an epoch change wipes
pending commands, transport resolutions, intents, and source revisions carried from the previous
generation; per-source revisions are monotone within an epoch pair and an accepted revision must
strictly advance its source; terminal intent outcomes are immutable; the pending table stays
coherent with its keys and intent records; intent retention stays within 128 plus active requests;
published timing is never negative; a gate (`accepts`) refusal implies a reduction (`reduce`)
refusal; `commandStarted` captures rollback from the pre-command presentation; and a rejected
finish for an undispatched pending command restores the fields that command claimed to the
pre-command values (a held seek with newer authoritative timing keeps that sample). Traces are
generated from a SplitMix64 seed, so a reported seed and step index reproduces the failing trace
exactly.
