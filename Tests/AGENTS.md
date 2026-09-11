# Deterministic check guidance

Use [verification](../docs/development/verification.md#normal-verification) for suite selection and
commands. Domain tests cover pure policy without Rust; boundary tests link the engine and exercise
injected SpottyCore workflows. No suite signs in, initiates live playback, or ships.

- Use reduced, synthetic fixtures following [PRIVACY.md](../PRIVACY.md).
- Preserve deterministic execution. The complete `Scripts/check.sh` gate must run every test target
  in full; focused local runs may filter tests.
- Test concurrency, lifetime, queue provenance, and rollback through behavior, not regex snapshots.
  Source checks are only for lexical or topology invariants.
- Reducer changes must keep `PlaybackReducerModelChecks` green. Prefer strengthening its invariants
  over adding more hand-enumerated interleavings; a failure reports the seed and step needed to
  reproduce the trace, and a genuinely new rule usually belongs there rather than in a new scenario.
- `SpottyBoundaryTests/Harness/` is the default set of injected dependencies: `HarnessEngine`,
  `HarnessRemote`, `HarnessWebQueue`, `HarnessAccount`, `HarnessPreferences`,
  `HarnessLifecycleEvents`, `HarnessAudioOutput`, `HarnessCatalog`, `HarnessTrackAttributes`,
  `HarnessPlaylistMutations`, `HarnessClock`, and `HarnessEnvironment.make(...)` /
  `makeStore(environment:feedback:)`. Every collaborator is defaulted and every method is
  overridable through a closure, so a check names only what it is about and shares one epoch
  (`HarnessDates.fixed`). Configure a harness fake rather than writing a new private one; a new
  private fake needs a reason the harness genuinely cannot express — conforming to two protocols
  at once, or an intricate script of its own — and a comment saying so.
- Boundary tests and helpers touching their state are `@MainActor`; the complete gate runs that
  target with `--no-parallel`. Use deterministic cooperative synchronization for polling and for
  negative assertions about completed effects, not blocking waits.
