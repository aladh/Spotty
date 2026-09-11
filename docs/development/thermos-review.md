# Thermos review

Thermos reviews open, ready PRs from this repository, including bot-authored PRs. It runs when a
PR is opened ready, marked ready, reopened, or pushed to. The first run audits the whole PR;
later runs audit only the changes since the head the previous Thermos review covered, so a fix
push gets a small follow-up review rather than a repeat of the first one. A force-push or rebase
falls back to a full review of the PR.

Two independent auditors inform actionable inline findings. Each run publishes one review as the
OpenCode App on the PR head: its body is the summary, its inline comments are the new findings.
The review approves when no new findings exist and no earlier Thermos thread remains
unresolved; otherwise it is a comment. Thermos never requests changes. An approval satisfies the
required approving review on `main`, and the branch rules dismiss it on the next push, so every
push is re-reviewed before merge. Approval means no actionable findings remained in the reviewed
scope; the summary states what the review could not exercise.

Each run also re-evaluates the still-open threads from earlier Thermos reviews against the new
head. A thread whose problem is gone, or whose author reply documents a disposition that holds up
against the code, gets a short reply and is resolved. Threads that still apply stay open. Declining
a finding therefore only needs a reply with the evidence or scope boundary; the next run resolves
the thread if the reasoning holds. PR readiness follows
[agent operations](../../CONTRIBUTING.md#pr-acceptance).

## Repeat a review

Comment `@thermos review` on the PR, or select **Run workflow** on **Thermos review**, choose the
default branch, and enter the PR number. Either posts another full review of the current head,
even if it was already reviewed. The PR must still be open, ready, and from this repository, and
the comment must come from the owner, a member, or a collaborator. Both paths run the workflow
and reviewer configuration from the default branch. A push while a review is running cancels that
run; the next run covers both pushes.

## Setup and trust

Install the [OpenCode GitHub App](https://github.com/apps/opencode-agent) on Spotty only. The
review agents run with a read-only repository token and never hold the App token. They write
findings, thread dispositions, and a summary as files, which a trusted workflow step validates
and publishes as the App: one review per head, thread replies and resolutions, and the approval
decision. Approval is computed from those files and from the live thread state, not asserted by
the agent. That step holds the App's installation token, whose pull-request write permission
covers reviews, approvals, thread replies, and resolutions; comment-versus-approve behavior is
workflow logic, not a credential restriction. A finding whose inline placement the API rejects is
published in the review body instead. Reviews refuse to run, or withhold approval, when a PR has
more review threads than one API page can return.

PR changes can affect reviewer configuration, since the workflow reads it from the PR merge
revision. The agents retain shell, edit, and web tools, so treating source, threads, and traces as
untrusted input does not enforce isolation. Author replies in threads are untrusted input to the
resolution decision. This is an accepted risk for this personal repository.

The summarizer receives no App token. Raw trace files are temporary and are not uploaded as
artifacts; the workflow log retains the summarizer output. Summarization can fail or be cut short
by the overall job timeout.

The contributor-free model provider may use submitted public source for Meta training.

See the [workflow](../../.github/workflows/thermos-review.yml) for execution details and
[agent configuration and rubrics](../../.github/thermos-review) for models, tools, prompts, the
GitHub review task, and the original Thermos license.

<!-- Thermos comment-trigger test; this PR is closed without merging. -->
