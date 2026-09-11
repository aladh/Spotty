# Semantic review and proof limits

[Enforcement inventory](../enforcement.md)

## Semantic agent-review families

| Judgment | Canonical owner |
| --- | --- |
| Product priorities, native behavior, truthful state, and bounded presentation cost | [Product contracts](../../product/README.md), [view guidance](../../../Sources/Spotty/Views/AGENTS.md) |
| Instruction ownership, work scope, verification, and PR execution | [AGENTS.md](../../../AGENTS.md), [agent operations](../../../CONTRIBUTING.md) |
| Composition, concurrency, ownership, and lifetime design | [Dependency ownership](../adrs/ADR-002-playback-state-and-dependencies.md), [task ownership](../adrs/ADR-003-playback-command-effects.md), [sole engine](../adrs/ADR-005-retain-librespot.md), [source policies](source-checks.md), [Spotify boundary guidance](../../../Sources/Spotty/Spotify/AGENTS.md) |
| Privacy-safe errors, diagnostics, and credential handling | [Privacy](../../../PRIVACY.md), [security](../../../SECURITY.md), [signing](../../development/signing.md) |
| Explicit, bounded live-account authorization | [Safe testing](../../product/safe-testing.md) |
| Generated state, dependency trust, and publication safety | [Local state](../../development/local-state.md), [release guide](../../development/releases.md), [workflow guidance](../../../.github/AGENTS.md) |

## Source-reading proof audit

Source checks prove syntax and topology, not runtime correctness. Review must still examine:

- **Lifetimes and ordering:** captured identities, stale completions, reentrancy, rollback, and
  production dependency wiring. Passing a reducer or command suite does not establish every
  asynchronous path.
- **Memory and boundaries:** allocation/free pairing, borrowed callback strings, lock-safe fan-out,
  and audio ownership transfer. ABI layout and signature checks do not prove these lifetimes.
- **Native interaction:** focus, keyboard dispatch, selection, accessibility, inactive windows,
  and Reduce Motion. Model-level view checks cannot establish actual control behavior.
- **Trust and failure:** credential exposure, private fixtures, cache/promotion provenance, partial
  writes, and useful recovery. Static structure is not proof of authorization or failure handling.

Use [behavior suites](behavior.md) for reproducible cases and [source policies](source-checks.md)
for exact structural boundaries. Do not replace either with prose assertions or duplicate code
snapshots; report what was actually checked and what remains a review judgment.
