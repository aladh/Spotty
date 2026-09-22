# Thermos review

Thermos reviews every open, ready PR from this repository, including bot-authored PRs, for
correctness and quality. Two independent auditors inform actionable inline findings; a coordinator
reconciles them and writes the summary. Its approval satisfies the required approving review on
`main`. Trigger phrase: `@thermos review`.

Thermos shares its triggers, incremental mode, publication, approval, thread handling, and trust
model with every other reviewer; see [agent reviews](agent-reviews.md). Thermos also claims review
threads that predate per-reviewer markers.

Behavior-changing descriptions declare affected product contracts, representative scenario IDs run,
scenario IDs added or changed, and unverified acceptance scope with reasons. Thermos compares those
declarations with the [head manifest](../../Tests/BrowsingHarness/Scenarios/manifest.json), changed
workloads and assertions, and the normalized CI artifact described in
[evidence and coverage](agent-reviews.md#evidence-and-coverage). Its summary names verified scenario
IDs and specific gaps. Missing or pending evidence is not a passing run; state assertions do not
establish visual fidelity, signed Demo isolation, live-account behavior or performance.

See the [caller workflow](../../.github/workflows/thermos-review.yml) and
[agent configuration and rubrics](../../.github/thermos-review) for models, tools, prompts, the
GitHub review task, and the original Thermos license.
