# Build and verification script agent guidance

Follow the [enforcement inventory](../docs/architecture/enforcement.md) when changing gates.

- Run scripts from the repository root and preserve their fail-fast, warning-clean behavior.
- `check.sh` is the ordinary complete verification gate. CI scopes may partition it, but no scope or
  cache change may reduce aggregate coverage.
- Prefer compiler, behavior suite, ABI fixture, or package-graph enforcement. Add a source check only
  for an exact lexical/topology invariant; never encode concurrency, lifetime, queue provenance,
  rollback, or payload semantics as source checks.
- App builds follow [ADR 006](../docs/architecture/adrs/ADR-006-prebuilt-playback-engine.md);
  engine publication follows the [artifact workflow](../docs/development/playback-artifacts.md).
- Changes to CI path classification in `ci_rust_policy.py` follow
  [workflow guidance](../.github/AGENTS.md).
- Keep `check-clean.sh` the clean Debug-and-Release owner. Do not add destructive cleanup that can
  erase unrelated work or credentials.
- Packaging and launch follow [development signing](../docs/development/signing.md); compile-only
  checks must not launch the app.
- `report-size.sh` is informational only: it reports release binary/archive size after
  `compile-release-spotty.sh` and must never fail the job over an optional tool (`size`, `nm`) being
  unavailable.
