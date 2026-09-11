Prioritize account/privacy/session safety, playback and lifetime correctness, then truthful state,
Spotify-familiar appearance, and native macOS interaction. Native implementation does not imply
replacing Spotify styling with macOS defaults. Keep scope small using the
[80/20 product principle](docs/product/scope.md#product-direction); optimize measured, user-visible costs.

## Development

- Use the [documentation index](docs/README.md) for product contracts and procedures.
- Spotty is maintained exclusively by agents. Finish implementation and relevant verification;
  report remaining blockers or unperformed acceptance steps.
- Follow [PR execution and acceptance](CONTRIBUTING.md#pull-request-execution).
- Choose [verification](docs/development/verification.md#normal-verification) proportional to the
  change and fix failures it causes. Documentation-only edits need no app build; reserve
  `Scripts/check-clean.sh` for work requiring a clean rebuild.
- Follow the [safe acceptance contract](docs/product/safe-testing.md#safe-acceptance-testing).
- Read the relevant [architecture decision](docs/architecture/adrs/README.md) before changing a boundary.
