# AGENTS.md

Spotty is an unofficial, independent, personal-use Spotify Premium client for
macOS 15+ on Apple Silicon, built with SwiftUI/AppKit, AVFoundation, and Rust/librespot.
No WebView, cross-platform shell, or supported Spotify API fallback.

Prioritize account/privacy/session safety, playback and lifetime correctness, then native macOS
behavior and truthful state. Keep scope small using the
[80/20 product principle](docs/product/scope.md#product-direction); optimize measured, user-visible costs.

## Development

- Use the [documentation index](docs/README.md) for product contracts and procedures.
- Spotty is maintained exclusively by agents. Finish implementation and relevant verification;
  report remaining blockers or unperformed acceptance steps.
- Follow [PR execution and acceptance](CONTRIBUTING.md#pull-request-execution).
- Signing/keychain changes, destructive cleanup, new production dependencies, external publication,
  and material scope expansion require explicit current-request authorization.
- Choose [verification](docs/development/verification.md#normal-verification) proportional to the
  change and fix failures it causes. Documentation-only edits need no app build; reserve
  `Scripts/check-clean.sh` for work requiring a clean rebuild.

## Live Spotify safety

Follow the [safe acceptance contract](docs/product/safe-testing.md#safe-acceptance-testing).
Launch or read-only acceptance does not authorize playback/account mutations. Do not launch to prove
compilation: the live `script/build_and_run.sh` path terminates the existing app and can disturb an
authenticated session. Launch only when authorized.

## Architecture

- Dependencies flow `SpottyApp -> SpottyCore -> SpottyDomain`. Keep the launcher thin, domain policy
  portable, and production dependency assembly at the composition root. Fakes, fixtures, and test
  hooks stay in non-shipping targets.
- Keep pinned Rust/librespot as the sole production playback engine, behind the narrow adapter;
  decoded PCM crosses to AVFoundation. Treat librespot updates as protocol and license changes,
  not routine dependency bumps. Do not add a parallel engine or protocol stack.
- Treat Swift concurrency diagnostics as correctness failures. Preserve isolation, ownership, and
  cancellation; do not bypass them with `nonisolated(unsafe)`, mutable globals, broad singletons,
  or detached task lifetimes.
- Keep errors actionable and privacy-safe. Follow [PRIVACY.md](PRIVACY.md) and [SECURITY.md](SECURITY.md);
  preserve them and `LICENSE`, `NOTICE`, and `THIRD_PARTY_NOTICES.md`.

## Documentation and instructions

Document intent, usage, and non-obvious constraints; link to code rather than duplicating mechanics.
Update the canonical owner and remove stale guidance. Keep review dispositions in review threads.
Use `AGENTS.md` for actionable project constraints: global rules here, path-specific rules in the
nearest file, and procedures in their canonical guide. Avoid task history and rules for one-off mistakes.
