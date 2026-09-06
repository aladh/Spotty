# Playback binary artifacts

[Agent operations](../../CONTRIBUTING.md) · Run commands from the repository root.

App builds consume the immutable engine release pinned in [Package.swift](../../Package.swift),
including matching headers and dependency notices. Changing Rust source does not change that pin;
a validated artifact and explicit pin update integrate an engine change into the app.

App tags use `vMAJOR.MINOR.PATCH`; engine tags use `playback-vMAJOR.MINOR.PATCH`. Choose an unused
three-component version without leading zeroes. Never overwrite published assets or remove assets
that older checkouts still use.

## Local engine development

Install the [engine tools](setup.md#engine-development), then build and test a local artifact:

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

## Publish a tested candidate

Publication requires explicit authorization. It promotes the exact candidate from a completed
main-branch push CI run, without rebuilding. The source must be merged and an ancestor of the
publisher checkout; PR and fork candidates cannot be published. Source policies, Rust, and candidate
Swift Debug/Release must pass in the selected run attempt. The tested commit becomes the release
target. Expired artifacts or a changed CI definition require a fresh main CI run.

CI tests a candidate when engine inputs differ from the pinned release, including unpublished
changes from earlier commits. Published-pin checks still verify the app's currently selected engine;
an app change requiring a newer ABI must update the pin.

Use the completed main push run's head SHA and run ID. Add `-f dry_run=true` to validate without
publishing:

```bash
: "${new_engine_version:?Set new_engine_version to an unused MAJOR.MINOR.PATCH version}"
gh workflow run playback-artifact.yml --ref main \
  -f version="$new_engine_version" \
  -f source_ref="$reviewed_source_sha" -f candidate_run_id="$candidate_ci_run_id"
```

The [publication workflow](../../.github/workflows/playback-artifact.yml) and
[promotion validator](../../Scripts/playback_promotion.py) own eligibility, provenance, integrity,
and notice checks. Publication must not execute candidate code or expose release credentials to it.

## Adopt the release

Download the published ZIP and update the pin. The updater validates the archive and computes its
checksum; current engine source need not match the selected release.

```bash
: "${new_engine_version:?Set new_engine_version to the published artifact version}"
./Backend/spotty-playback/update-artifact-pin.sh \
  --archive /absolute/path/SpottyPlaybackCore.xcframework.zip \
  --version "$new_engine_version"
unset SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK
SPOTTY_CHECK_SCOPE=swift ./Scripts/check.sh
./Scripts/compile-release-spotty.sh
```

Commit the pin update in a PR. See [ADR 006](../architecture/adrs/ADR-006-prebuilt-playback-engine.md)
for the binary-distribution decision and relinking constraints.
