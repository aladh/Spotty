# Thermos review

Thermos provides advisory correctness and quality reviews for open, ready PRs from this
repository, including bot-authored PRs. It runs when a PR is opened ready or marked ready;
pushes do not trigger another review, and a published summary prevents automatic repeats.

Two independent auditors inform actionable inline findings and a summary posted by the
OpenCode App. Findings focus on changes introduced or made reachable by the PR. A separate
trace summary in the workflow log describes the review and its coverage. Reviews are
advisory; PR readiness follows [agent operations](../../CONTRIBUTING.md#pr-acceptance).

## Repeat a review

Select **Run workflow** on **Thermos review**, choose the default branch, and enter the
PR number. This posts another review of the current changes, even if a summary already
exists. The PR must still be open, ready, and from this repository.

## Setup and trust

Install the [OpenCode GitHub App](https://github.com/apps/opencode-agent) on Spotty only.
The review uses its identity and broader write permissions; comment-only behavior is
prompt policy, not a credential restriction. PR changes can affect reviewer configuration.
The agents retain shell, edit, and web tools, so treating source and traces as untrusted
input does not enforce isolation. This is an accepted risk for this personal repository.

The summarizer receives no App token directly. Raw trace files are temporary and are not
uploaded as artifacts; the workflow log retains the summarizer output. Interrupted runs
may leave partial comments, and retries can duplicate them. Summarization can fail or be
cut short by the overall job timeout.

The contributor-free model provider may use submitted public source for Meta training.

See the [workflow](../../.github/workflows/thermos-review.yml) for execution details and
[agent configuration and rubrics](../../.github/thermos-review) for models, tools, prompts,
and the original Thermos license.
