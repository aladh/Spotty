# Deterministic check guidance

Use [verification](../docs/development/verification.md#normal-verification) for suite selection and
commands. Domain tests cover pure policy without Rust; boundary tests link the engine and exercise
injected SpottyCore workflows. Neither suite signs in, initiates live playback, or ships.

- Use reduced, synthetic fixtures following [PRIVACY.md](../PRIVACY.md).
- Preserve deterministic execution. The complete `Scripts/check.sh` gate must run both targets in
  full; focused local runs may filter tests.
- Test concurrency, lifetime, queue provenance, and rollback through behavior, not regex snapshots.
  Source checks are only for lexical or topology invariants.
- Reducer changes must keep `PlaybackReducerModelChecks` green. Prefer strengthening its invariants
  over adding more hand-enumerated interleavings; a failure reports the seed and step needed to
  reproduce the trace, and a genuinely new rule usually belongs there rather than in a new scenario.
- Boundary tests and helpers touching their state are `@MainActor`; the complete gate runs that
  target with `--no-parallel`. Use its shared `waitUntil` for async polling and
  `PlaybackEffectRegistry.settlement(of:)` for negative assertions about completed effects, not
  fixed sleeps or blocking waits. Domain tests retain their own cooperative waits.
