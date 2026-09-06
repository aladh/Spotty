# Semantic review and proof limits

[Enforcement inventory](../enforcement.md)

## Semantic agent-review families

| IDs | Judgment | Canonical owner |
| --- | --- | --- |
| `DOC-PRI-001`, `DOC-PROD-001`, `DOC-TASTE-001`, `DOC-UI-001`, `DOC-CACHE-001` | Product priorities, native behavior, truthful state, and bounded presentation cost | [Product contracts](../../product/README.md), [view guidance](../../../Sources/Spotty/Views/AGENTS.md) |
| `DOC-AGENT-001`, `DOC-DOD-001`, `DOC-MAP-001`, `DOC-VER-001`, `DOC-PR-001` | Instruction ownership, work scope, verification, and PR execution | [AGENTS.md](../../../AGENTS.md), [agent operations](../../../CONTRIBUTING.md) |
| `DOC-IMPL-001`, `DOC-CONC-001`, `DOC-ESCAPE-001`, `DOC-ARCH-001` | Composition, concurrency, ownership, and lifetime design | [Dependency ownership](../adrs/ADR-002-playback-state-and-dependencies.md), [task ownership](../adrs/ADR-003-playback-command-effects.md), [Spotify boundary guidance](../../../Sources/Spotty/Spotify/AGENTS.md) |
| `DOC-LOG-001`, `DOC-SEC-001`–`002` | Privacy-safe errors, diagnostics, and credential handling | [Privacy](../../../PRIVACY.md), [security](../../../SECURITY.md), [signing](../../development/signing.md) |
| `DOC-SAFE-001` | Explicit, bounded live-account authorization | [Safe testing](../../product/safe-testing.md) |
| `DOC-GEN-001`, `DOC-DEP-001`, `DOC-CI-001`, `DOC-REL-001` | Generated state, dependency trust, and publication safety | [Local state](../../development/local-state.md), [release guide](../../development/releases.md), [workflow guidance](../../../.github/AGENTS.md) |

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
