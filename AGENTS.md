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
- Follow the [safe acceptance contract](docs/product/safe-testing.md#safe-acceptance-testing).
- Read the relevant [architecture decision](docs/architecture/adrs/README.md) before changing a boundary.

## Documentation and instructions

Document intent, usage, and non-obvious constraints; link to code rather than duplicating mechanics.
Update the canonical owner and remove stale guidance. Keep review dispositions in review threads.
Use `AGENTS.md` for actionable project constraints: global rules here, path-specific rules in the
nearest file, and procedures in their canonical guide. Avoid task history and rules for one-off mistakes.
