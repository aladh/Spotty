# Architecture decisions

ADRs explain consequential choices and their tradeoffs. Read the relevant decision when changing a
boundary; routine implementation work does not require reading the whole history.

## Current decisions

| Record | Decision |
| --- | --- |
| [ADR 001: Playback engine boundary](ADR-001-playback-engine.md) | Contain private protocol work behind one C module and Swift adapter. |
| [ADR 002: Playback state and dependency ownership](ADR-002-playback-state-and-dependencies.md) | Use one reducer-owned presentation snapshot and explicit dependency and lifetime owners. |
| [ADR 003: Playback command effects](ADR-003-playback-command-effects.md) | Keep `PlaybackEffectRegistry`; no TCA or generic Effect abstraction for the current architecture. |
| [ADR 005: Retain librespot](ADR-005-retain-librespot.md) | Keep the pinned Rust/librespot leaf as the sole production engine; no replacement roadmap. |
| [ADR 006: Prebuilt playback engine](ADR-006-prebuilt-playback-engine.md) | Consume a checksum-pinned XCFramework for ordinary app builds; retain explicit engine source workflows. |

## Historical decisions

[ADR 004: Incremental Swift ownership migration](ADR-004-swift-owned-playback-logic.md) was superseded
by ADR 005. Consult it for historical reasoning, not current work instructions.

## Where other information belongs

| Need | Owner |
| --- | --- |
| Canonical product, ownership, verification, setup, and operations docs | [Repository guide](../AGENTS.md#canonical-documents) |
| Private extended-metadata protocol notes | [Extended metadata](extended-metadata.md) |

## Maintaining the decision log

- Record consequential context, decisions, alternatives, tradeoffs, and useful revisit triggers.
- Correct facts and references in place; unchanged decisions do not need a new record.
- For reversals, add the next numbered record, mark the old one superseded, and link both ways.
- State each record's status (proposed, accepted, rejected, or superseded) and keep this index current.
- Link to canonical owners for commands, fields, and behavior cases; omit delivery progress.
