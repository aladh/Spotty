# Architecture enforcement inventory

This inventory maps rules to their canonical owners and strongest available proof.
**Semantic agent review** means inspection of code, tests, diffs, and decisions by the implementing
agent and available automated reviewers. It is not compiler, test, ABI, or source-check proof.

PR readiness follows the [acceptance criteria](../../CONTRIBUTING.md#pr-acceptance).
Semantic agent review does not add a human-review requirement beyond repository settings or a manual
app-testing gate.

## Enforcement order

Use the strongest owner that can express the invariant without lying about what it proves:

1. compiler, package graph, or platform configuration;
2. deterministic behavior tests;
3. ABI/signature/cross-language fixtures;
4. a narrow source or topology check for genuinely lexical rules;
5. semantic agent review for product judgment, taste, scope, and failure-mode analysis.

Do not promote concurrency, epochs, queue provenance, lifecycle, optimistic rollback, or payload
correctness into regex snapshots. Conversely, do not rely on prose when the package graph or a small
source check can own an exact boundary.

Stable IDs preserve searchability in issue and code history. They are navigation, not an API.

## Mechanically enforced families

- [Build, ABI, and CI](enforcement/build-and-abi.md): toolchain, package graph, cross-language contracts, and workflows.
- [Deterministic behavior](enforcement/behavior.md): state, lifetimes, protocol projections, and mutations.
- [Source and topology](enforcement/source-checks.md): lexical boundaries and retired rule IDs.

## Semantic review

[Review families and proof limits](enforcement/review.md) cover judgment rules and the source-reading proof audit.
