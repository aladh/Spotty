# Thermos review

Thermos reviews every open, ready PR from this repository, including bot-authored PRs, for
correctness and quality. Two independent auditors inform actionable inline findings; a coordinator
reconciles them and writes the summary. Its approval satisfies the required approving review on
`main`. Trigger phrase: `@thermos review`.

Thermos shares its triggers, incremental mode, publication, approval, thread handling, and trust
model with every other reviewer; see [agent reviews](agent-reviews.md). Thermos also claims review
threads that predate per-reviewer markers.

See the [caller workflow](../../.github/workflows/thermos-review.yml) and
[agent configuration and rubrics](../../.github/thermos-review) for models, tools, prompts, the
GitHub review task, and the original Thermos license.
