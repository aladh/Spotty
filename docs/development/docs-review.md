# Documentation review

Every open, ready, same-repository PR receives a comment-only documentation review, including code
changes that may need documentation. Unresolved findings block merge; this reviewer never approves
or requests changes. Trigger: `@docs-review review`. [Agent reviews](agent-reviews.md) owns the shared
workflow, reruns, and trust limits.

## What it reviews

A coordinator reconciles two Spotty-owned rubrics:

- [Sense](../../.github/docs-review/sense.md): accuracy, missing updates, links, canonical ownership,
  and useful copy. Passing the [size limit](../../Scripts/documentation_policy.py) does not establish concision.
- [Specification guard](../../.github/docs-review/spec.md): classifies governed edits and checks
  declarations against code/contracts. It owns the governed-document list;
  [product guidance](../product/AGENTS.md) requires preserving intended requirements during cleanup.

For requirement, rule, or record changes, declare the old text's meaning, the new one, and why it
changes. Justified declared decisions are summarized; the maintainer owns them. Missing-update
findings identify the canonical owner and the code creating the gap.

## Limits

Code/doc inspection cannot establish runtime or visual behavior. A declaration added after review
needs another run. These rubrics are Spotty's own, independent of Thermos.

The [caller workflow](../../.github/workflows/docs-review.yml) and
[configuration](../../.github/docs-review) own models, tools, and orchestration.
