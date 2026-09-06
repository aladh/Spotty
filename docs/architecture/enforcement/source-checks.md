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

| IDs | Boundary |
| --- | --- |
| `SRC-DOM-001`, `SRC-FFI-001`–`002` | Domain imports and the narrow C-adapter entry points |
| `SRC-DEP-001` | Live dependency construction stays out of views and feature stores |
| `SRC-ISO-001`, `SRC-INOUT-001` | Unsafe isolation escapes and split revision ownership |
| `SRC-UI-001`, `SRC-DUP-004` | Appearance ownership and unsupported drag APIs |
| `SRC-HYG-001`, `CI-TOOL-001`, `ABI-ARC-001` | Retired Swift symbols; syntax-only facets of Rust-free app scripts and workflow action/credential/published-engine policies |
| `SRC-KEY-001` | Retired Keychain APIs |
| `SRC-RUST-FFI-001`, `SRC-RUST-PLAY-001` | Panic-barrier/runtime entry and playing-event write ownership |

Additional owners:

- `SRC-PROJ-001`: [compiler access probes](../../../Scripts/check-playback-projection-access.sh).
- `SRC-HYG-002`–`004`: [check.sh](../../../Scripts/check.sh), gitignore, and privacy review.
- `SRC-SIGN-001`: signing assertions in [check.sh](../../../Scripts/check.sh), plus the
  [signing contract](../../development/signing.md). Spelling checks do not establish Keychain trust.

Retired IDs `SRC-OBS-001`–`003`, `SRC-WRITER-001`, `SRC-DUP-003`, `CI-OBS-001`,
`CI-SWIFT-001`, and `ABI-JSON-001` remain historical references. Do not recreate duplicate snapshots
of behavior now covered by the package graph, deterministic suites, or semantic review.
