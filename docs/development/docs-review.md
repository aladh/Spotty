# Documentation review

Every open, ready, same-repository PR receives a comment-only documentation review, including code
changes that may need documentation. It never approves or requests changes; unresolved findings
still block merge. Trigger: `@docs-review review`. See [agent reviews](agent-reviews.md) for shared
triggers, incremental review, publication, reruns, and trust limits.

## What it reviews

A coordinator reconciles two Spotty-owned rubrics:

- [Sense](../../.github/docs-review/sense.md): accuracy at the PR head, canonical ownership,
  missing updates, working links, and useful copy. It checks for duplicated procedures,
  implementation inventories, and new pages without a distinct reader need. Passing the
  [CI size limit](../../Scripts/documentation_policy.py) does not establish concision.
- [Specification guard](../../.github/docs-review/spec.md): classifies governed edits as wording,
  corrections to verified behavior, or changes to requirements, rules, or records. It checks the
  PR's declarations against code and contracts, including policy limits and exemptions. The rubric
  owns the governed-document list; [product guidance](../product/AGENTS.md) requires preserving
  intended requirements during cleanup.

Declare the old requirement, the new one, and why it changes in the PR description. Justified,
declared decisions are summarized rather than reported as findings; the maintainer owns those
decisions. Missing-update findings identify the canonical owner and the code line creating the gap.

## Limits

This review reads code and docs without building or running the app. It cannot establish runtime
or visual behavior. A declaration added after review needs another run; Thermos remains the only
automated approver. These prompts are Spotty's own, independent of Thermos.

The [caller workflow](../../.github/workflows/docs-review.yml) and
[configuration](../../.github/docs-review) own models, tools, and orchestration.
