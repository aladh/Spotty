# Playback binary artifacts

[Agent operations](../../CONTRIBUTING.md) · Run commands from the repository root.

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

For engine development, install the [artifact tools](setup.md#engine-development)
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
