# Playback engine ownership

Spotty builds its playback engine as an internal module of the Rust app. [Architecture decision](adrs/ADR-011-rune-playback-module.md)

## Rune

The [playback module](../../Rune/src/playback/mod.rs) owns Spirc, session generation and lifecycle. [Typed commands](../../Rune/src/playback/client.rs)
carry the generation and typed arguments. The engine captures connection, playback and queue facts
at their originating revision and calls the native observer after releasing engine locks. The one
librespot sink supplies borrowed stereo PCM to Rune’s [audio output](../../Rune/src/live/audio.rs).

The [Rune session worker](../../Rune/src/live/mod.rs) owns account, catalog and presentation state.
Its [serial command thread](../../Rune/src/live/playback_thread.rs) runs synchronous engine work off
the UI and app Tokio workers. [Command evidence](../../Rune/src/live/intent.rs) holds a permit across
the write and uses later observations to confirm the result. Account retirement revokes admission
before clearing presentation and applies the durable sign-out or reauthentication change on the
same thread.

Native recovery captures sticky track, context, seek position and modes before the replacement
session starts. The engine queues the context target first, tries the single track if the context
cannot be queued, and waits for matching Playing evidence before publishing readiness. A superseded generation cannot confirm a replacement’s load or queue mutation.

## Historical Swift implementation

The earlier Swift app and its artifact pin remain in source. Its [original ownership guide](https://github.com/aladh/Spotty/blob/9b5d72b686ac094148b395006918cc1215cbb8e3/docs/architecture/playback-engine-ownership.md) describes the Swift/C interface for that revision.
