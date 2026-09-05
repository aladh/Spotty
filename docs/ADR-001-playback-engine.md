# ADR 001: Playback engine boundary

Status: accepted on 2026-08-18; the engine choice is reaffirmed by [ADR 005](ADR-005-retain-librespot.md).

## Context and decision

Spotty needs standalone playback and Spotify Connect with a native macOS interface. Private
session, media delivery, decoding, and reconnection work should not spread through application code.

Contain that work behind one C module and one Swift adapter. Swift owns application state and
policy; decoded PCM goes directly to the native AVFoundation renderer. The boundary must allow an
engine replacement without making the application depend on librespot internals.

[ADR 005](ADR-005-retain-librespot.md) owns engine choice and revisit conditions;
[ADR 006](ADR-006-prebuilt-playback-engine.md) owns binary distribution. Replaceability does not
imply a migration roadmap.

## Tradeoff

A foreign-function boundary adds ABI and lifetime verification, but limits the reach of private
protocol changes. Adding another application-facing engine abstraction would add indirection
without improving that containment.

Current modules and responsibilities are listed in [playback engine ownership](playback-engine-ownership.md);
ABI and import checks are indexed in the [enforcement inventory](architecture-enforcement.md).
