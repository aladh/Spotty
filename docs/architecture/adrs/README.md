# Architecture decisions

[Documentation index](../../README.md)

ADRs explain consequential choices and their tradeoffs. Read the relevant decision when changing a
boundary; routine implementation work does not require reading the whole history.

## Current decisions

| Record | Decision |
| --- | --- |
| [ADR 001: Playback engine boundary](ADR-001-playback-engine.md) | Contain private protocol work behind one C module and Swift adapter. |
| [ADR 002: Playback state and dependency ownership](ADR-002-playback-state-and-dependencies.md) | Keep atomic reducer state and lifetime checks; runtime ownership is superseded by ADR 008. |
| [ADR 003: Playback command effects](ADR-003-playback-command-effects.md) | Keep explicit effects and intent settlement; runtime ownership is superseded by ADR 008. |
| [ADR 005: Retain librespot](ADR-005-retain-librespot.md) | Keep the pinned Rust/librespot leaf as the sole production engine; no replacement roadmap. |
| [ADR 006: Prebuilt playback engine](ADR-006-prebuilt-playback-engine.md) | Consume a checksum-pinned XCFramework for ordinary app builds; retain explicit engine source workflows. |
| [ADR 007: File-backed session persistence](ADR-007-session-persistence.md) | Store the OAuth grant in a private file independently of release signing. |
| [ADR 008: Headless session runtime](ADR-008-headless-session-runtime.md) | Put account/playback authority on a dedicated session executor; use an in-process desktop client with a typed transport seam. |
| [ADR 009: Account catalog retention](ADR-009-account-catalog-retention.md) | Retain bounded browsing results with account admission, freshness, occurrence identity, and purge fences. |
| [ADR 010: Native dense surfaces](ADR-010-native-dense-surfaces.md) | Own dense tables and scrolling directly in AppKit while preserving Spotify styling. |

## Historical decisions

[ADR 004: Incremental Swift ownership migration](ADR-004-swift-owned-playback-logic.md) was superseded
by ADR 005. Consult it for historical reasoning, not current work instructions.

## Maintaining the decision log

- Record consequential context, decisions, alternatives, tradeoffs, and useful revisit triggers.
- Correct facts and references in place; unchanged decisions do not need a new record.
- For reversals, add the next numbered record, explain what it replaces, mark the old one superseded,
  and link both ways.
- State each record's status (proposed, accepted, rejected, or superseded) and keep this index current.
- Link to canonical owners for commands, fields, and behavior cases; omit delivery progress.
