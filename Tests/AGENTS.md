# Deterministic check guidance

Use [verification](../docs/development/verification.md#normal-verification) for suite selection and
commands. Domain tests cover pure policy without Rust; boundary tests link the engine and exercise
injected SpottyCore workflows. No suite signs in, initiates live playback, or ships.

- Use reduced, synthetic fixtures following [PRIVACY.md](../PRIVACY.md).
- Preserve deterministic execution. The complete `Scripts/check.sh` gate must run every test target
  in full; focused local runs may filter tests.
- Test concurrency, lifetime, queue provenance, and rollback through behavior, not regex snapshots.
  Source checks are only for lexical or topology invariants.
- Place implementation checks in the target owning the behavior. Gateway-only checks must build
  without the desktop or engine; cross-module workflows remain in `SpottyBoundaryTests`.
- Reducer changes must keep `PlaybackReducerModelChecks` green. Prefer strengthening its invariants
  over adding more hand-enumerated interleavings; a failure reports the seed and step needed to
  reproduce the trace, and a genuinely new rule usually belongs there rather than in a new scenario.
- Use [shared runtime fixtures](SpottyRuntimeTestSupport) for injected dependencies in runtime
  and boundary tests. Privileged environment factories stay in each test target; desktop factories
  stay in Boundary. Configure only relevant collaborators and share one epoch
  (`HarnessDates.fixed`). Configure a harness fake rather than writing a new private one; a new
  private fake needs a reason the harness genuinely cannot express — conforming to two protocols
  at once, or an intricate script of its own — and a comment saying so.
  Catalog feature fixtures return domain snapshots directly; keep private wire shapes, decoding,
  and mapping assertions in Gateway tests. Use real gateways only for cross-module integration checks.
  Preserve narrow owner fixtures that reject unexpected work; shared defaults do not replace those assertions.
- Shared clocks, preferences, response gates, and bounded prerequisites live in
  [SpottyTestSupport](SpottyTestSupport); their contracts run independently in
  [SpottyTestSupportTests](SpottyTestSupportTests). Follow the
  [synchronization guide](../docs/development/verification.md#deterministic-synchronization)
  when testing deadlines or suspended dependencies.
- Assert scalar values or small snapshots. Prefer Boolean comparisons over negating a member
  expression when failure diagnostics would otherwise expand the owning runtime or fixture graph.
- Boundary tests and helpers touching their state are `@MainActor`; the complete gate runs that
  target with `--no-parallel`. Use deterministic cooperative synchronization for polling and for
  negative assertions about completed effects, not blocking waits.
