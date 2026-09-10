# Deterministic check guidance

Use [verification](../docs/development/verification.md#normal-verification) for suite selection and
commands. Domain tests cover pure policy without Rust; boundary tests link the engine and exercise
injected SpottyCore workflows. No suite signs in, initiates live playback, or ships.

- Use reduced, synthetic fixtures following [PRIVACY.md](../PRIVACY.md).
- Preserve deterministic execution. The complete `Scripts/check.sh` gate must run every test target
  in full; focused local runs may filter tests.
- Test concurrency, lifetime, queue provenance, and rollback through behavior, not regex snapshots.
  Source checks are only for lexical or topology invariants.
- Boundary tests and helpers touching their state are `@MainActor`; the complete gate runs that
  target with `--no-parallel`. Use deterministic cooperative synchronization for polling and for
  negative assertions about completed effects, not fixed sleeps or blocking waits.
