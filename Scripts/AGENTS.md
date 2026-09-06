# Build and verification script agent guidance

These scripts are repository policy executables, not convenience wrappers. Read the relevant
sections of [agent operations](../CONTRIBUTING.md) and the
[enforcement inventory](../docs/architecture/enforcement.md) before changing gate behavior.

- Run scripts from the repository root and preserve their fail-fast, warning-clean behavior.
- `check.sh` is the ordinary complete verification gate. CI scopes may partition it, but no scope or
  cache change may reduce aggregate coverage.
- Prefer compiler, behavior suite, ABI fixture, or package-graph enforcement. Add a source check only
  for an exact lexical/topology invariant; never encode concurrency, lifetime, queue provenance,
  rollback, or payload semantics as source checks.
- Keep `check-clean.sh` the clean Debug-and-Release owner. Do not add destructive cleanup that can
  erase unrelated work or credentials.
- `script/build_and_run.sh` terminates a running Spotty executable and can touch an authenticated
  development session. Do not route compile-only verification through launch.
- Never install project-generated identities in the login keychain or weaken signing to silence
  prompts.
- `report-size.sh` is informational only: it reports release binary/archive size after
  `compile-release-spotty.sh` and must never fail the job over an optional tool (`size`, `nm`) being
  unavailable.
