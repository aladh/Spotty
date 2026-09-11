# Documentation review

The documentation review runs on open, ready PRs from this repository that change `docs/`,
`README.md`, `PRIVACY.md`, `SECURITY.md`, `CONTRIBUTING.md`, or any `AGENTS.md`. It limits its
diffs to those paths and skips PRs that touch none of them. It is comment-only: it never approves
and never requests changes, and its open threads block merge through the thread-resolution rule
until they are resolved. Trigger phrase: `@docs-review review`.

It shares its triggers, incremental mode, publication, approval, thread handling, and trust model
with every other reviewer; see [agent reviews](agent-reviews.md). Its prompts are Spotty's own and
do not derive from Thermos.

## What it reviews

Two subagents inspect the same change, and a coordinator reconciles them:

- **Sense.** Each changed claim about the repository is true at the head; content sits in the
  canonical owner named by the [documentation index](../README.md) and is linked rather than
  duplicated; text follows the root `AGENTS.md` documentation guidance (intent and constraints, no
  task history, no restated mechanics); links and anchors resolve; the change reads correctly in
  context.
- **Specification guard.** Every hunk in a governed document is classified as wording, a
  correction of a product contract to verified shipped behavior, or a change of requirement, rule,
  or record. Governed documents are the [product contracts](../product/README.md) under
  `docs/product/`, the root and nested `AGENTS.md` files and `CONTRIBUTING.md`, published release
  notes under `docs/releases/`, dated measurement sections and JSON in `docs/architecture/`, and
  accepted ADR decisions. A correction or change must be declared in the PR description with the
  old and new requirement and the reason, as [product documentation guidance](../product/AGENTS.md)
  requires; an undeclared one is a finding even when the new text is more accurate. Corrections are
  checked against `Sources/` and `Backend/` at the head.

Declared and justified changes are not findings; the summary names them so a reader of the review
sees which product or rule decisions the PR carries. The review does not judge whether a declared
product decision is right; the maintainer owns that.

## Limits

The review reads documents and code; it does not build or run the app, so it cannot verify
claims about runtime behavior beyond what source and tests show. It checks the PR description as
written at review time; a declaration added later is picked up by the next run, which resolves the
thread. Thermos's approval remains the only automated approval.

See the [caller workflow](../../.github/workflows/docs-review.yml) and
[agent configuration and prompts](../../.github/docs-review) for models, tools, the task, and the
subagent rubrics.
