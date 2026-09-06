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

Swift and Rust rules live in `Scripts/ast-grep/rules`, with shared matchers in
`Scripts/ast-grep/utils`; allowed/forbidden fixtures live in `Tests/SourcePolicy`.
The wrapper runs those fixtures, Python file-routing tests, and the production scan. CI uses the
pinned `ast-grep/action` for scanning and the wrapper's `--test-only` mode for fixtures and owner
presence checks. When changing a
rule, cover comments/strings, relevant syntax variations, and file-owner exceptions. These are syntax
policies, not type or runtime proofs: the pinned Swift grammar can recover valid Swift expressions
as error nodes. Swift compilation remains authoritative; do not treat a clean scan as a parse check.

The full and Rust scopes require the [engine toolchain](setup.md#engine-development).
The Swift scope and packaging use the pinned binary without Rust tools. Checks do not sign in or
initiate playback. See the [enforcement inventory](../architecture/enforcement.md) for coverage.

After changing a Rust ABI declaration, run `./Scripts/generate-c-header.sh` and commit the generated
header. `--check` verifies reproducibility; set `SPOTTY_CBINDGEN` if the pinned tool is not on `PATH`.

`Backend/spotty-playback/cbindgen.toml` generates
`Sources/SpottyPlaybackCore/include/spotty_playback_generated.h`. Edit the Rust declarations and
their ownership documentation, then regenerate; never edit the generated header. Keep Swift-specific
nullable-pointer and open-enum annotations in `spotty_playback_annotations.h`. Do not enable
cbindgen's global nullable-pointer annotation: it would make required callback pointers nullable.

Extend `Scripts/check-c-header-imports.sh` when adding a pointer shape; it compile-checks Swift
imports and nullability without running playback.

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

CI's required `Debug quality gate` aggregates Linux source policies, Rust, Swift/architecture, and
Release compilation.

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
