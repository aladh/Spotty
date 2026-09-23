# Thermos review

Thermos reviews every open, ready PR from this repository, including bot-authored PRs, for
correctness and quality. Two independent auditors inform actionable inline findings; a coordinator
reconciles them and writes the summary. Its approval satisfies the required approving review on
`main`. Trigger phrase: `@thermos review`.

Follow [PR declarations](../../CONTRIBUTING.md#pull-request-execution) for behavior changes.
Thermos compares them with the head manifest, changed workloads/assertions, and matching CI evidence;
its summary names verified scenario IDs and coverage gaps.

[Agent reviews](agent-reviews.md) owns triggers, incremental review, publication, thread ownership,
reruns, trust, and evidence limits.

The [caller workflow](../../.github/workflows/thermos-review.yml) and
[configuration](../../.github/thermos-review) own orchestration, rubrics, and the original license.
