# ADR 011. Build playback into the Rune app

Status: accepted for the Rune app.

Spotty compiles its internal Rust playback module and the pinned librespot sources in the same Cargo target as the Rune application. The module exposes typed observations and commands. Blocking engine operations run on the app’s dedicated serial command thread. The generation fences, readiness evidence, credential lifetime and confirmation rules from the original engine remain applicable.

This decision supersedes the C module, static archive, published XCFramework and Swift adapter requirements of ADRs 001, 005, 006 and 008 for the current app. The earlier Swift source and its published checksum-pinned artifact remain available for historical builds. [Playback ownership](../playback-engine-ownership.md) · [Verification](../../development/verification.md)
