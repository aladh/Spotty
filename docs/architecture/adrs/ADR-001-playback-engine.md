# ADR 001: Playback engine boundary

Status: accepted on 2026-08-18; the engine choice is reaffirmed by [ADR 005](ADR-005-retain-librespot.md).

## Context and decision

Spotty needs standalone playback and Spotify Connect with a native macOS interface. Private
session, media delivery, decoding, and reconnection work should not spread through application code.

Contain that work behind one C module and one Swift adapter. Swift owns application state and
policy; decoded PCM goes directly to the native AVFoundation renderer. The boundary must allow an
engine replacement without making the application depend on librespot internals.

The adapter is its own SwiftPM target, `SpottyEngineAdapter`: it alone depends on the
`SpottyPlaybackCore` binary, and `PlaybackCore` is internal to it. Containment is therefore a
package-graph fact the compiler enforces, not a convention a new import could quietly break.
`SpottySessionRuntime` consumes its typed ports; the adapter may also depend on portable domain
values, shared runtime contracts, and diagnostics. The desktop presentation target does not
import the engine adapter or binary. [ADR 008](ADR-008-headless-session-runtime.md) owns runtime
isolation and the choice to keep the production engine and renderer in the app process.

[ADR 005](ADR-005-retain-librespot.md) owns engine choice and revisit conditions;
[ADR 006](ADR-006-prebuilt-playback-engine.md) owns binary distribution. Replaceability does not
imply a migration roadmap.

## Tradeoff

A foreign-function boundary adds ABI and lifetime verification, but limits the reach of private
protocol changes. Adding another application-facing engine abstraction would add indirection
without improving that containment.

Responsibility boundaries are described in [playback engine ownership](../playback-engine-ownership.md);
ABI and import checks are indexed in the [enforcement inventory](../enforcement.md).
