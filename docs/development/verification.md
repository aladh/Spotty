# Build and verification

[Agent operations](../../CONTRIBUTING.md) · Run commands from the repository root.

## Build and run

For an authorized launch, from the repository root:

```bash
./script/build_and_run.sh
```

This verifies, builds, signs, and replaces the running app; do not use it as a compile check.
Modes include `--verify`, `--release`, `--verify-release`, and `--telemetry`.
See [launch constraints](../../script/AGENTS.md) and
[signing setup](signing.md) before authenticated launches.

## Normal verification

Use the smallest focused check per [AGENTS.md](../../AGENTS.md#local-verification). Available gate scopes:

```bash
./Scripts/check.sh
./Scripts/check-source-policy.sh
SPOTTY_CHECK_SCOPE=swift ./Scripts/check.sh
SPOTTY_CHECK_SCOPE=rust ./Scripts/check.sh
```

The full gate includes source policies; CI runs those once in the Linux `Source policies` job,
separately from the Swift and Rust scopes. `check-source-policy.sh` needs Python 3 and ast-grep
at the version in `Scripts/ast-grep/version`. Install with `brew install ast-grep` when Homebrew
provides that version, or install the exact CLI with npm:

```bash
npm install --prefix /tmp/spotty-ast-grep "@ast-grep/cli@$(cat Scripts/ast-grep/version)"
SPOTTY_AST_GREP=/tmp/spotty-ast-grep/node_modules/.bin/ast-grep ./Scripts/check-source-policy.sh
```

[Source policies](../architecture/enforcement/source-checks.md) index the rules and their limits.
When changing a rule, cover syntax variants and file-owner exceptions. A clean syntax scan does
not replace Swift compilation or behavior tests.

The full and Rust scopes require the [engine toolchain](setup.md#engine-development).
The Swift scope and packaging use the pinned binary without Rust tools. Checks do not sign in or
initiate playback. See the [enforcement inventory](../architecture/enforcement.md) for coverage.

CI uses one macOS job for conditional Rust verification/candidate production, then Swift Debug
checks and the Release distribution compile. Debug and Release share one SwiftPM cache under a
combined key; separate configuration directories remain inside `.build`. CI restores source timestamps
only when tracked Swift input contents match the manifest saved with that build cache; changed and
new inputs keep checkout timestamps. Rust verification disables incremental products and keeps line-table
debug information to reduce cache transfer without changing assertions or test coverage. Release
caches include Cargo host tools as well as target products. Rust tools are blocked
before Swift runs. Main requires `Source policies` and `macOS checks`. The final macOS step validates each phase
outcome, including the explicit decision required to skip Rust.

CI skips macOS for PRs limited to documentation, including nested `AGENTS.md` files. Linux source
policies still run. Other PRs skip Rust only when limited to app sources/tests, assets, packaging, package pins, or
documentation. Engine, shared-header, CI, script, license, and unknown paths require Rust; main always
runs it. The Linux source-policy job uses the PR base commit's classifier. A base without the policy
requires Rust; a base without macOS classification keeps macOS enabled. Detection errors fail CI. Skipped Rust steps are accepted only after an
explicit successful app-only decision. Pinned cbindgen binaries are cached by version, runner image/architecture, and Rust toolchain,
with a version check before reuse. See [CI policy](../../Scripts/ci_rust_policy.py) for exact paths.

After changing a Rust ABI declaration, run `./Scripts/generate-c-header.sh` and commit the generated
header. `--check` verifies reproducibility; set `SPOTTY_CBINDGEN` if the pinned tool is not on `PATH`.

Edit Rust declarations and regenerate; never hand-edit generated headers. Preserve callback and
pointer ownership annotations under the [C-boundary guidance](../../Sources/SpottyPlaybackCore/AGENTS.md).
Extend `Scripts/check-c-header-imports.sh` when adding a pointer shape.

Swift formatting:

```bash
./Scripts/format-swift.sh --check
./Scripts/format-swift.sh --write
```

Tests live in `Tests/SpottyDomainTests/` and `Tests/SpottyBoundaryTests/`. Discover names with
`swift test list`, then filter for focused iteration:

```bash
swift test --disable-sandbox --filter ProtobufTests/testProtobuf
swift test --disable-sandbox --no-parallel --filter AuthFlowTests/testAuthFlow
```

Use `SPOTTY_CHECK_REPEATS=N ./Scripts/check.sh` with `N` from 1 through 25 when concurrency or
lifetime work merits stress.

## Clean and risk-specific verification

For clean-build changes or diagnosis requiring a rebuild:

```bash
./Scripts/check-clean.sh
```

This removes generated Swift build products, rebuilds the engine artifact, and verifies Debug and
Release. Preserve unrelated work. Use `./Scripts/compile-release-spotty.sh` for compile-only Release
verification.

## Diagnostics

Release builds use Unified Logging. `./Scripts/export-diagnostics.sh` writes a bounded report under
ignored `diagnostics/`. Handle reports according to [PRIVACY.md](../../PRIVACY.md).
