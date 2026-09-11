# Rust playback leaf agent guidance

Keep the Rust/librespot leaf within [engine ownership](../../docs/architecture/playback-engine-ownership.md)
and [ADR 005](../../docs/architecture/adrs/ADR-005-retain-librespot.md). ABI changes follow the
[engine contract](../../docs/architecture/engine-contract.md).

- `EngineGeneration` in `state.rs` owns everything scoped to one engine generation — session,
  Spirc, player, mixer, player-event sender, task registry, playing flag and its event stamp,
  resume claim, playback options, cluster caches, and the connection fields — behind one
  `ENGINE` mutex tagged with its `session_generation`. Reach it only through the `state.rs`
  accessors; use `with_engine_owned` / `with_connection_owned` whenever the caller names a
  generation, so a stale owner is refused with `StaleGeneration` instead of overwriting its
  replacement. Lifecycle operations that write it still serialize through one async lifecycle
  mutex. The engine guard must never escape an accessor, cross an `await`, or be held while a
  Swift callback runs, and no helper may re-enter the lifecycle mutex.
- Only `EngineGeneration::note_playing_event` can report local playback: the flag is private, so
  a play or load command cannot claim success the player never reported. This replaces the
  retired `rust-playing-store-owner` / `rust-playing-store-required` ast-grep rules.
- Reconnect captures `SESSION_GENERATION` at trigger time and revalidates it after acquiring the
  lifecycle mutex. A stale cleanup/reconnect must not tear down or rebuild a newer generation.
  Exported init rechecks its already-initialized no-op inside the mutex.
- A superseded grant/run must not write credentials or lifecycle state. Routine cleanup is not grant
  supersession; preserve the distinct generation rules and their tests.
- Every `spotty-playback` `extern "C"` export enters through the panic-barrier helpers in `ffi.rs`.
  Use `block_on_export`; call `refuse_if_nested_runtime` before mutating flags that nested `block_on`
  would have reached. Nested runtime re-entry returns `ERROR_GENERAL` and is not supersession.
- Map panics to the defined sentinel. Do not replace the process panic hook, hold Rust locks while
  invoking Swift, or assume the barrier makes invalid foreign pointers safe.
- Emit bounded PCM and immutable typed observations with non-blocking callbacks. Preserve the
  engine contract's readiness hold and sticky resume identity.
- Keep decoded PCM on `proxy_sink`; do not reintroduce a parallel audio/protocol path, debug selector,
  Swift decoder, or player-injection seam.
- Keep the checked-in C header, exported symbol set, signatures, ownership, allocation, and callback
  lifetime aligned.
- Treat librespot changes as protocol migrations. Preserve the documented Swift/Rust responsibility
  boundary instead of opportunistically expanding the Rust leaf.
