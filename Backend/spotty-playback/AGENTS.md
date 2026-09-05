# Rust playback leaf agent guidance

This crate is the contained Rust/librespot protocol, Connect, streaming, decoding, recovery, and
C-ABI leaf. Read [ADR 001](../../docs/ADR-001-playback-engine.md),
[ADR 005](../../docs/ADR-005-retain-librespot.md), and
[playback engine ownership](../../docs/playback-engine-ownership.md) before moving responsibility
across the Swift/Rust boundary.

## Lifecycle and ownership

- Lifecycle operations that write `SESSION`, `SPIRC`, `PLAYER`, `MIXER`, or `PLAYER_EVENT_TX`
  serialize through one async lifecycle mutex. Do not hold a per-global guard across `await`, and do
  not re-enter the lifecycle mutex from an inner helper.
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
- Rust emits bounded PCM and immutable protocol/state envelopes; callbacks stay non-blocking.
  Connection, playback, device-list, and queue observations are typed C snapshots, not JSON.
  Presentation and resume plans stay in Swift. Preserve the reconnect readiness hold and keep
  sticky context confined to resume-load getters; follow
  [playback engine ownership](../../docs/playback-engine-ownership.md) when changing these boundaries.
- Keep decoded PCM on `proxy_sink`; do not reintroduce a parallel audio/protocol path, debug selector,
  Swift decoder, or player-injection seam.
- Keep the checked-in C header, exported symbol set, signatures, ownership, allocation, and callback
  lifetime aligned.
- Treat librespot changes as protocol migrations. Preserve the ownership classification instead of
  opportunistically expanding the Rust leaf.
