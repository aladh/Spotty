# Architecture decisions

[Documentation index](../../README.md)

ADRs explain consequential choices and their tradeoffs. Read the relevant decision when changing a
boundary; routine implementation work does not require reading the whole history.

## Current app

[ADR 011. Internal playback in the Rune app](ADR-011-rune-playback-module.md) owns the current build and runtime boundary. ADR 005’s librespot choice and ADR 007’s persistence rules also apply.

## Swift architecture records

The summary below identifies each decision's current scope. Partially superseded records retain
their applicable rules and link to the successor that owns the replaced choices. Repository history
preserves earlier implementation details; current records should not instruct agents to use them.

| Record | Status | Current decision |
| --- | --- | --- |
| [ADR 001: Playback engine boundary](ADR-001-playback-engine.md) | Superseded by ADR 011 | Historical C module and Swift adapter. |
| [ADR 002: Playback state and dependency ownership](ADR-002-playback-state-and-dependencies.md) | Partially superseded by ADR 008 | Keep atomic reducer state, lifetime checks, and prepared projections. Runtime and dependency ownership follow ADR 008. |
| [ADR 003: Playback command effects](ADR-003-playback-command-effects.md) | Partially superseded by ADR 008 | Keep explicit effects, dispatch admission, and intent settlement. Effect ownership and revalidation follow ADR 008. |
| [ADR 005: Retain librespot](ADR-005-retain-librespot.md) | Accepted | Keep the pinned Rust/librespot leaf as the sole production engine; no replacement roadmap. |
| [ADR 006: Prebuilt playback engine](ADR-006-prebuilt-playback-engine.md) | Superseded by ADR 011 | Historical Swift builds consume a checksum-pinned XCFramework. |
| [ADR 007: File-backed session persistence](ADR-007-session-persistence.md) | Accepted | Store the OAuth grant in a private file independently of release signing. |
| [ADR 008: Headless session runtime](ADR-008-headless-session-runtime.md) | Partially superseded by ADR 011 | Preserve account and playback ownership on a dedicated executor and settle typed intents against observed state. |
| [ADR 009: Account catalog retention](ADR-009-account-catalog-retention.md) | Accepted | Retain bounded browsing results with account admission, freshness, occurrence identity, and purge fences. |
| [ADR 010: Native dense surfaces](ADR-010-native-dense-surfaces.md) | Accepted | Own dense tables and scrolling directly in AppKit while preserving Spotify styling. |

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
