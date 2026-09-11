# Source and topology enforcement

[Enforcement inventory](../enforcement.md)

The [ast-grep rules](../../../Scripts/ast-grep/rules) are the canonical specification for checked
syntax, file scope, and exceptions. Keep exact API exclusions and required statement shapes there,
with their diagnostics and proof limits, rather than repeating them in agent instructions.
Changing a rule changes repository policy and needs corresponding positive, negative, and routing
coverage. Run the rules through
[check-source-policy.sh](../../../Scripts/check-source-policy.sh), following
[verification setup](../../development/verification.md#normal-verification).

Rules and [fixtures](../../../Tests/SourcePolicy) are grouped into
[Swift](../../../Scripts/ast-grep/rules/swift), [Rust](../../../Scripts/ast-grep/rules/rust),
[shell](../../../Scripts/ast-grep/rules/shell), and
[workflows](../../../Scripts/ast-grep/rules/workflows). The
[routing tests](../../../Scripts/test_source_policy.py) check owner exceptions, new files,
fixture coverage, and missing or empty [required owners](../../../Scripts/ast-grep/required-files.txt).
CI and local scans use the same roots, including tests and build/launch scripts.

These checks do not resolve symbols, follow aliases, establish execution order, or replace
compilation and behavior tests. In particular, presence of signing statements does not prove they
execute before termination; logging through one owner does not sanitize dynamic fields; and API
exclusions cannot detect a custom cache or environment access disguised behind an arbitrary helper.
The pinned Swift and Bash grammars can recover valid Swift or zsh as error nodes, so a clean scan
is not a parse guarantee. Review new syntax and owner exceptions against the actual boundary.

Additional owners:

- Playback projection access: [compiler access probes](../../../Scripts/check-playback-projection-access.sh).
- Repository text and artifact hygiene: [repository-text checks](../../../Scripts/check-source-policy.sh),
  [artifact hygiene](../../../Scripts/check.sh), the
  [notices preamble prefix check](../../../Scripts/test_notices_policy.py), gitignore, and privacy review.
- Signing validity and non-destructive launch ordering: the
  [signing contract](../../development/signing.md) and [validation](../../../Scripts/validate-app.sh).

The compiler owns the outer playback target boundary, the private engine mutex and playing flag,
and unavailable domain imports in the [Linux lane](build-and-abi.md). Behavior suites own ordering,
epochs, rollback, queue provenance, and callback lifetimes. Product contracts and ADRs retain the
intended behavior and architectural rationale; a syntax rule does not replace those decisions.
