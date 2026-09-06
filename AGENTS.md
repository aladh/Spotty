# AGENTS.md

Spotty is an experimental, unofficial, independent, personal-use Spotify Premium client for
macOS 15+ on Apple Silicon. It uses SwiftUI/AppKit and AVFoundation with a contained Rust/librespot
playback and Connect leaf. No WebView, Chromium shell, cross-platform UI, or supported Spotify API
fallback. Keep the experimental and no-affiliation warnings prominent in public material.

Prioritize account/privacy/session safety, then playback and lifetime correctness, then native macOS
behavior and truthful state. Keep the product surface small; apply the
[80/20 product principle](docs/product/scope.md#product-direction) when choosing
features, and optimize measured, user-visible costs.

## Working in this repository

- Check `git status --short` and preserve unrelated work.
- Before editing, read the applicable `AGENTS.md` chain. Discover tracked instruction files with
  `git ls-files | rg '(^|/)AGENTS\.md$'` from the repository root.
- Load only relevant documents; inspect the affected implementation, checks, and recent history,
  using the [documentation index](docs/README.md) to find canonical owners rather than duplicating
  their rules.
- Reviews, explanations, diagnoses, and plans are read-only unless changes are requested.
  For changes, complete in-scope work and non-destructive validation without routine approval.
- Spotty is maintained exclusively by agents: complete agent-operable work and report unperformed
  acceptance steps honestly.
- PR requests authorize branch/commit/push, opening the PR, and addressing automated review per
  [agent operations](CONTRIBUTING.md#pull-request-execution). They do not authorize merging,
  tagging, releases, repository settings, or unrelated issue mutations.
- Use the [PR acceptance criteria](CONTRIBUTING.md#pr-acceptance) to determine
  readiness; do not add a manual review or app-testing gate.
- Signing/keychain changes, destructive cleanup, new production dependencies, external publication,
  and material scope expansion require explicit current-request authorization.

## Live Spotify safety

Follow the [safe acceptance contract](docs/product/safe-testing.md#safe-acceptance-testing)
for live-account work. Launch or read-only acceptance does not authorize playback/account mutations.
Do not launch merely to prove compilation: `./script/build_and_run.sh` terminates an existing
process and can disturb an authenticated session. Use it only when the request authorizes launch
or interactive acceptance.

## Architecture

- Swift dependencies flow `SpottyApp -> SpottyCore -> SpottyDomain`. Keep the executable launcher
  thin, domain policy portable, and the C/Rust leaf behind the narrow playback adapter.
- Assemble production dependencies at the composition root. Fakes, synthetic fixtures, and test
  hooks stay in non-shipping tests.
- Treat Swift concurrency diagnostics as correctness failures. Preserve explicit isolation,
  ownership, and cancellation; do not bypass them with `nonisolated(unsafe)`, mutable globals,
  broad singletons, or detached task lifetimes.
- User-facing errors must be actionable and privacy-safe. Follow [PRIVACY.md](PRIVACY.md) and
  [SECURITY.md](SECURITY.md). Preserve these files and `LICENSE`, `NOTICE`, and
  `THIRD_PARTY_NOTICES.md`.
- Keep the pinned Rust/librespot leaf as the sole production playback implementation; decoded PCM
  crosses the narrow adapter to AVFoundation. Treat librespot updates as protocol and license
  changes, not routine dependency bumps, and do not add a parallel engine or protocol stack.

## Code, test, and documentation quality

- Avoid speculative abstractions and pass-through wrappers; helpers should clarify logic or remove
  meaningful duplication.
- Tests must catch plausible behavioral failures, not mirror implementation or duplicate coverage.
- Skip obvious comments and production hooks added solely to test trivial code.
- Document intent, usage, and non-obvious constraints; let code describe mechanics. Link to the
  implementation instead of maintaining a prose copy of its steps, variables, or configuration.
  Keep concrete commands and details when needed to use, verify, or safely change the system.
- Before adding documentation, check the canonical owner. Update or replace existing guidance;
  remove stale or redundant wording. Omit task history and repeated rationale. Record review
  dispositions in the review thread rather than expanding permanent guides with each discussion.

## Local verification

Run the smallest focused check that exercises the change; commands are in
[build and verification](docs/development/verification.md#normal-verification). Reserve `./Scripts/check-clean.sh` for
clean-build changes or diagnosis requiring a clean rebuild. PR CI covers Rust, Swift/Debug, and
Release compilation but does not run that clean-room gate.

## Maintaining instructions

Use `AGENTS.md` for repository instructions. Keep only non-obvious, actionable project constraints:
global rules here, path-specific gotchas in the nearest file, procedures in their canonical document.
Link instead of repeating policy or implementation details. When behavior changes, update the owner
and remove stale guidance; do not accumulate rules for one-off mistakes.
