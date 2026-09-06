# Deterministic check guidance

`SpottyDomainTests` covers pure policy and is Rust-free. `SpottyBoundaryTests` covers concrete
SpottyCore adapters, stores, and injected workflows; it needs the playback archive at link time.
Both targets use Swift Testing with synthetic/injected workflows and never ship. Local checks do not
sign in or initiate playback; focused runs and fixes need no live-account authorization.
Filtering commands are in
[build and verification](../docs/development/verification.md#normal-verification).

- Use reduced, synthetic fixtures following [PRIVACY.md](../PRIVACY.md).
- Preserve deterministic execution. The complete `Scripts/check.sh` gate must run both targets in
  full; focused local runs may filter tests.
- Test concurrency, lifetime, queue provenance, and rollback through behavior, not regex snapshots.
  Source checks are only for lexical or topology invariants.
- Boundary tests and helpers touching their state are `@MainActor`; the complete gate runs that
  target with `--no-parallel`. Use its shared `waitUntil` for async polling and
  `PlaybackEffectRegistry.settlement(of:)` for negative assertions about completed effects, not
  fixed sleeps or blocking waits. Domain tests retain their own cooperative waits.
