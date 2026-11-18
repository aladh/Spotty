# ADR 011. Build playback into the Rune app

Status: accepted for the Rune app.

Spotty compiles its internal Rust playback module and the pinned librespot sources in the same Cargo target as the Rune application. The module exposes typed observations and commands. Blocking engine operations run on the app’s dedicated serial command thread. The generation fences, readiness evidence, credential lifetime and confirmation rules from the original engine remain applicable.

This decision replaces the C module, static archive, published XCFramework, and Swift-specific boundaries. The app retains the librespot choice from [ADR 005](ADR-005-retain-librespot.md) and lifetime and settlement rules from [ADR 008](ADR-008-headless-session-runtime.md). [Playback ownership](../playback-engine-ownership.md) · [Verification](../../development/verification.md)
