# Playback binary artifacts

[Agent operations](../../CONTRIBUTING.md) · Run commands from the repository root.

App builds consume the immutable engine release pinned in [Package.swift](../../Package.swift),
including matching headers and dependency notices. Changing Rust source does not change that pin;
a validated artifact and explicit pin update integrate an engine change into the app.

App tags use `vMAJOR.MINOR.PATCH`; engine tags use `playback-vMAJOR.MINOR.PATCH`. Choose an unused
three-component version without leading zeroes. Never overwrite published assets or remove assets
that older checkouts still use.

## Local engine development

Install the [engine tools](setup.md#engine-development), run the Rust checks, and build the
artifact independently of the app:

```bash
SPOTTY_CHECK_SCOPE=rust ./Scripts/check.sh
./Backend/spotty-playback/build-xcframework.sh
```

Rust checks own header generation and producer ABI validation. Swift CI consumes only published
artifacts, rejecting noncanonical or unversioned release URLs before dependency resolution.
[Verification](verification.md#normal-verification) defines when app-only PRs may skip the Rust steps.

## Publish a tested candidate

Publication requires explicit authorization. It promotes the exact candidate from a completed
main-branch push CI run, without rebuilding. The source must be merged and an ancestor of the
publisher checkout; PR and fork candidates cannot be published. Source policies and the Rust verification, candidate build, and upload steps must pass
in the selected run attempt. The artifact creation time must fall inside that upload step. Later
Swift steps validate the published app pin independently and do not gate engine publication. The tested commit becomes the release target. Expired artifacts or a changed
CI definition require a fresh main CI run.

CI builds candidates for engine-input or build/validation infrastructure changes relative to the
PR base or previous main push. Unrelated app-only changes do not rebuild unpublished engines; select
the earlier engine-changing main run when the latest run has no candidate. Missing bases build
conservatively, while comparison failures fail CI. An app change requiring a newer ABI must update
its published pin.

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
