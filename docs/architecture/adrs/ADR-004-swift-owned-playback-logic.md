# ADR 004: Move Spotty-owned playback logic into Swift incrementally

Status: superseded on 2026-09-04 by [ADR 005](ADR-005-retain-librespot.md).
This historical record is not an active migration plan.

## Historical decision

The Rust leaf had accumulated application-facing projections and orchestration alongside protocol
work. The decision was to move coherent application responsibilities into Swift incrementally,
with deterministic checks, instead of attempting a big-bang engine rewrite.

## Why it was superseded

The later Swift playback experiment introduced a second implementation and additional lifetime and
verification costs without an established benefit. ADR 005 retired the replacement roadmap and
retained librespot as the sole production engine.
