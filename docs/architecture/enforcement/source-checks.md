# Source and topology enforcement

[Enforcement inventory](../enforcement.md)

## Focused source and topology checks

[ast-grep rules](../../../Scripts/ast-grep/rules) own syntax policies; their
[fixtures](../../../Tests/SourcePolicy) and [routing checks](../../../Scripts/test_source_policy.py)
exercise matching and file scope. Run them through
[check-source-policy.sh](../../../Scripts/check-source-policy.sh), following
[verification setup](../../development/verification.md#normal-verification).

These checks do not resolve symbols, establish execution order, or replace compilation and behavior
tests. The pinned Swift grammar can recover valid Swift as error nodes, so a clean scan is not even
a Swift parse guarantee. Review owner scope when introducing files or new syntax.

| Boundary | Rule files |
| --- | --- |
| Domain imports and the narrow C-adapter entry points | `domain-imports.yml`, `ffi-import-owner.yml`, `ffi-import-required.yml`, `playback-core-owner.yml`, `playback-core-required.yml` |
| Live dependency construction stays out of views and feature stores | `injected-dependencies.yml` |
| Unsafe isolation escapes and split revision ownership | `unsafe-isolation.yml`, `revision-inout.yml` |
| Appearance ownership and unsupported drag APIs | `dark-appearance-required.yml`, `fixed-appearance.yml`, `unsupported-drag-ui.yml` |
| Retired Swift symbols | `retired-mock-symbols.yml` |
| Rust-free app scripts, workflow action pins and checkout credentials, and published-engine use in CI (syntax-only facets; see [build and CI](build-and-abi.md#ci-and-release-workflow)) | `app-script-rust-free.yml`, `workflow-action-pins.yml`, `workflow-checkout-credentials.yml`, `ci-published-engine.yml` |
| Panic-barrier/runtime entry and playing-event write ownership | `rust-ffi-panic-barrier.yml`, `rust-runtime-owner.yml`, `rust-playing-store-owner.yml`, `rust-playing-store-required.yml` |

Additional owners:

- Playback projection access: [compiler access probes](../../../Scripts/check-playback-projection-access.sh).
- Repository text and artifact hygiene: [repository-text checks](../../../Scripts/check-source-policy.sh),
  [artifact hygiene](../../../Scripts/check.sh), the
  [notices preamble prefix check](../../../Scripts/test_notices_policy.py), gitignore, and privacy review.
- Signing: signing assertions in [check.sh](../../../Scripts/check.sh), plus the
  [signing contract](../../development/signing.md). Spelling checks do not establish signature validity.

Do not recreate duplicate snapshots of behavior now covered by the package graph, deterministic
suites, or semantic review.
