# Playback binary artifacts

[Agent operations](../../CONTRIBUTING.md) · Run commands from the repository root.

App releases use `vMAJOR.MINOR.PATCH`; playback releases use `playback-vMAJOR.MINOR.PATCH` in the
same repository. Engine publication takes a new version independent of the app version.
Versions have three numeric components without leading zeroes; existing tags and releases cannot
be reused. Hashes remain internal artifact/cache identities and integrity checks.

`Package.swift` is the single dependency pin: a hardcoded release URL and SHA-256 checksum for
the SwiftPM binary target. SwiftPM fetches that exact versioned release asset, rather than resolving
prefixed Git tags as package versions. Update the pin with the updater below. The artifact bundles
the ARM64 library, matching headers/module map, provenance, and dependency notices. Never overwrite a published asset.

The Swift package and Rust crate are independent projects in this repository. App builds and Swift
checks consume the pinned artifact and its bundled headers, even when engine source has changed.
Rust checks own source/header generation and producer ABI validation. Swift CI never selects an
unpublished engine. Updating the app pin to a published release is the integration step.

For engine development, install the [artifact tools](setup.md#engine-development), run the Rust
checks, and build the artifact independently of the app:

```bash
SPOTTY_CHECK_SCOPE=rust ./Scripts/check.sh
./Backend/spotty-playback/build-xcframework.sh
```

CI compares engine inputs against the PR base or the previous main push commit. It builds a
candidate only when those inputs or candidate build/validation infrastructure change, including
shared headers, packaging scripts, and license inputs. An absent or initial base SHA builds a
candidate conservatively; a failed comparison fails CI. Unpublished engine changes already on main
do not trigger candidate builds for unrelated PRs. Rust checks and published-artifact Swift checks
remain required on every run. Content digests identify build caches and artifact provenance.

Publication promotes the exact candidate ZIP from a completed CI run, without rebuilding it. Run
the publisher after Source policies and Rust succeed in the candidate's main push CI run. Swift
jobs validate the app's published pin independently and do not gate engine publication. The selected
source must be a merged commit covered by that run and an ancestor of the publisher checkout.
PR and fork candidates cannot be published. The tested main commit becomes the release target.
When a later app-only commit produces no candidate, select the earlier engine-changing main run.

The publisher verifies the CI definition matches its trusted checkout, the source ancestry on main,
successful jobs from the same run attempt, artifact identity/checksum, and embedded provenance and
notices. It never executes candidate code and keeps release credentials in a separate Linux job.
Expired artifacts or candidates from an older CI definition require a fresh CI run. Keep app and
engine release identities separate; published playback releases are never overwritten.

Use the completed main push CI run's head SHA and run ID to promote an explicitly authorized
candidate (use `-f dry_run=true` to validate without publishing). Set `new_engine_version` to an
unused version; publication rejects existing release identities:

```bash
: "${new_engine_version:?Set new_engine_version to an unused MAJOR.MINOR.PATCH version}"
gh workflow run playback-artifact.yml --ref main \
  -f version="$new_engine_version" \
  -f source_ref="$reviewed_source_sha" -f candidate_run_id="$candidate_ci_run_id"
```

Download the release ZIP and update the package pin; the updater validates the bundled artifact
and computes its checksum without requiring current engine source to match:

```bash
: "${new_engine_version:?Set new_engine_version to the published artifact version}"
./Backend/spotty-playback/update-artifact-pin.sh \
  --archive /absolute/path/SpottyPlaybackCore.xcframework.zip \
  --version "$new_engine_version"
unset SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK
SPOTTY_CHECK_SCOPE=swift ./Scripts/check.sh
./Scripts/compile-release-spotty.sh
```

Commit the pin update in a PR. Publication rejects dirty source; the updater only writes versioned
pins. Preserve published assets that older checkouts still reference.
