# Agent operations for Spotty

Start with [AGENTS.md](AGENTS.md). Prerequisites, toolchain pins, signing, and local state are in
[development setup](docs/development-setup.md).

## Build and run

For an authorized launch, from the repository root:

```bash
./script/build_and_run.sh
```

This verifies, builds, signs, and replaces the running app; do not use it as a compile check.
Modes include `--verify`, `--release`, `--verify-release`, and `--telemetry`.
See [launch constraints](script/AGENTS.md) and
[signing setup](docs/development-setup.md#fresh-clone) before authenticated launches.

## Normal verification

Use the smallest focused check per [AGENTS.md](AGENTS.md#local-verification). Available gate scopes:

```bash
./Scripts/check.sh
SPOTTY_CHECK_SCOPE=swift ./Scripts/check.sh
SPOTTY_CHECK_SCOPE=rust ./Scripts/check.sh
```

The full and Rust scopes require the [engine toolchain](docs/development-setup.md#engine-development).
The Swift scope and packaging use the pinned binary without Rust tools. Checks do not sign in or
initiate playback. See the [enforcement inventory](docs/architecture-enforcement.md) for coverage.

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

CI's required `Debug quality gate` aggregates Rust, Swift/architecture, and Release compilation.

Use `SPOTTY_CHECK_REPEATS=N ./Scripts/check.sh` with `N` from 1 through 25 when concurrency or
lifetime work merits stress.

## Playback binary artifacts

App releases use `vMAJOR.MINOR.PATCH`; playback releases use `playback-vMAJOR.MINOR.PATCH` in the
same repository. Engine publication takes a version such as `0.1.0`, independent of the app version.
Versions have three numeric components without leading zeroes; existing tags and releases cannot
be reused. Hashes remain internal artifact/cache identities and integrity checks.

`Package.swift` is the single dependency pin: a hardcoded release URL and SHA-256 checksum for
the SwiftPM binary target. SwiftPM
fetches that exact versioned release asset, rather than resolving prefixed Git tags as package
versions. Update the pin with the updater below. The artifact bundles the ARM64 library, matching
headers/module map, provenance, and dependency notices. Never overwrite a published asset.

The Swift package and Rust crate are independent projects in this repository. App builds and Swift
checks consume the pinned artifact and its bundled headers, even when engine source has changed.
Rust checks own source/header generation; candidate Swift checks exercise the new engine. Updating
the app pin is the explicit integration step. The existing source layout remains unchanged.

For engine development, install the [artifact tools](docs/development-setup.md#engine-development)
and build a local artifact:

```bash
./Backend/spotty-playback/build-xcframework.sh
engine_digest="$(./Backend/spotty-playback/source-input-digest.sh)"
export SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK="$PWD/.build/playback-engine/$engine_digest/SpottyPlaybackCore.xcframework"
SPOTTY_CHECK_SCOPE=swift ./Scripts/check.sh
./Scripts/compile-release-spotty.sh
```

Rebuild and refresh the override after every engine-input change. Preserve digest-bearing paths
and library names so SwiftPM relinks changed engines. The override selects a binary without building
Rust; unset it to return to the published dependency. Run the Rust gate separately.

CI diffs engine build inputs against the app's pinned `playback-vMAJOR.MINOR.PATCH` tag. It builds
and tests a candidate only when those inputs differ, including shared headers, packaging scripts,
and license inputs. Comparing with the pinned release also catches unpublished engine changes from
earlier commits. Until the legacy pin is replaced with a versioned release, every run builds a
candidate to bootstrap publication. Rust source checks and published-artifact Swift checks remain
required; content digests still identify build caches and artifact provenance.

Publication promotes the exact candidate ZIP from a completed CI run, without rebuilding it. Run
the publisher from main after Rust and candidate Swift Debug/Release succeed. Published-pin jobs
continue to test the app against its selected release; they fail if app changes require a newer ABI. The selected source must be a
merged commit covered by a main-branch push CI run and an ancestor of the publisher checkout.
PR and fork candidates cannot be published. The tested main commit becomes the release target.

The publisher verifies the CI definition matches its trusted checkout, the source ancestry on main,
successful jobs from the same run attempt, artifact identity/checksum, and embedded provenance and
notices. It never executes candidate code and keeps release credentials in a separate Linux job.
Expired artifacts or candidates from an older CI definition require a fresh CI run. Keep app and
engine release identities separate; published playback releases are never overwritten.

Use the completed main push CI run's head SHA and run ID to promote an explicitly authorized
candidate (use `-f dry_run=true` to validate without publishing):

```bash
gh workflow run playback-artifact.yml --ref main \
  -f version="0.1.0" \
  -f source_ref="$reviewed_source_sha" -f candidate_run_id="$candidate_ci_run_id"
```

Download the release ZIP and update the package pin; the updater validates the bundled artifact
and computes its checksum without requiring current engine source to match:

```bash
./Backend/spotty-playback/update-artifact-pin.sh \
  --archive /absolute/path/SpottyPlaybackCore.xcframework.zip \
  --version "0.1.0"
unset SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK
SPOTTY_CHECK_SCOPE=swift ./Scripts/check.sh
./Scripts/compile-release-spotty.sh
```

Commit the pin update in a PR. Publication rejects dirty source and existing release identities.
The existing hash-based pin remains supported during migration; the updater only writes versioned
pins. Publish the first version and adopt its pin before removing any legacy release assets that
current checkouts still reference.

## Clean and risk-specific verification

For clean-build changes or diagnosis requiring a rebuild:

```bash
./Scripts/check-clean.sh
```

This removes generated Swift build products, rebuilds the engine artifact, and verifies Debug and
Release. Preserve unrelated work. Use `./Scripts/compile-release-spotty.sh` for compile-only Release
verification.

## Package, sign, and notarize

Local packages are development artifacts:

```bash
./Scripts/package-app.sh --debug
./Scripts/package-app.sh --release
./Scripts/validate-app.sh --local
```

A hardened-runtime Developer ID archive requires an explicitly supplied identity:

```bash
SPOTTY_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  ./Scripts/archive-app.sh
```

The archive is written to ignored `dist/`. Notarization additionally requires an existing Apple
`notarytool` profile:

```bash
SPOTTY_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
SPOTTY_NOTARY_PROFILE="spotty-notary" \
  ./Scripts/notarize-app.sh
```

`validate-app.sh --distribution` requires a Developer ID signature, a valid notarization ticket, and
Gatekeeper acceptance. Signing proves artifact integrity; it does not make the private Spotify
integration supported or policy-compliant. Engine publication generates and inspects transitive
licenses from `Cargo.lock`; app packaging copies them from the pinned artifact.

## Tagged releases

An authorized `vX.Y.Z` tag must match `CFBundleShortVersionString` in `Packaging/Info.plist`. The
release workflow verifies the app against the pinned engine and publishes an ARM64 experimental
prerelease ZIP and SHA-256 checksum. Until Developer ID and notarization credentials are configured,
artifacts use hardened-runtime ad-hoc signing; release notes must state that macOS will not
automatically trust them. Renovate owns dependency updates.

## Diagnostics

Release builds use Unified Logging. `./Scripts/export-diagnostics.sh` writes a bounded report under
ignored `diagnostics/`. Handle reports according to [PRIVACY.md](PRIVACY.md).

## Pull-request execution

A request to open a PR authorizes the agent to create a branch, commit the complete in-scope change,
push it, open the PR, monitor available checks/reviews during the run, and address automated
findings. It does not authorize merge, release, tag, repository-setting changes, or issue closure
unless the request says so.

### PR acceptance

A PR is ready when all three conditions hold for its latest changes:

1. All review findings have a documented disposition and all review threads are resolved.
2. Required approvals are satisfied according to repository settings.
3. Checks are green: every applicable check has passed, with only intentional conditional skips.

Evaluate review feedback using engineering judgment. Addressing feedback does not require agreeing
with or implementing every suggestion. Fix valid issues; when declining a suggestion, explain the
reasoning, tradeoff, or scope boundary in the thread. Resolve threads only after documenting their
disposition.

After pushing fixes, wait for checks and required reviews to cover the updated head. A stale
blocking review state must be cleared through the reviewer’s normal workflow; do not bypass
repository protections.

Manual app testing is not a PR acceptance gate, and no human review is required beyond repository
settings. Report automated coverage limits honestly; separately requested manual verification may
happen after merge. Live-account work still follows the
[safe acceptance contract](docs/product-and-acceptance-contract.md#safe-acceptance-testing).
Meeting these criteria establishes readiness, not permission to merge: merge authorization remains
separate as described above.
