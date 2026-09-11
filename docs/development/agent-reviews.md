# Agent reviews

Spotty runs automated PR reviews through one shared pipeline, the
[reusable review workflow](../../.github/workflows/agent-review.yml). Each reviewer is a thin
caller workflow that owns its triggers and passes its configuration directory, review marker,
primary agent, and optional path filter. Current reviewers:

- [Thermos review](thermos-review.md): correctness and quality of every ready PR.
- [Documentation review](docs-review.md): sense and product-specification guard for PRs that
  touch documentation; comment-only.

## Shared behavior

A reviewer runs when a PR from this repository is opened ready, marked ready, reopened, or pushed
to, and on request (a trigger comment or **Run workflow** on the default branch). The first run
audits the whole PR; later runs audit only the changes since the head that reviewer last covered,
so a fix push gets a small follow-up rather than a repeat. A force-push or rebase falls back to a
full review. A reviewer with a path filter skips PRs whose changed files do not match it and limits
its diffs to matching files.

The agents run with a read-only repository token and never hold the App token. They write
`findings.json`, `thread-actions.json`, and `summary.md`; a trusted workflow step validates those
files and publishes one review per head as the OpenCode App: the summary as the body, the findings
as inline comments on the head commit, and replies and resolutions for that reviewer's earlier
threads. A reviewer configured to approve does so when no new findings exist and none of its earlier
threads remains unresolved; otherwise, and for comment-only reviewers always, the review is a
comment. Reviewers never request changes. An approval means no actionable findings remained in the
reviewed scope; the summary states what the review could not exercise. Branch rules dismiss
approvals on the next push, so every push is re-reviewed before merge.

Each run re-evaluates that reviewer's still-open threads against the new head. A thread whose
problem is gone, or whose author reply documents a disposition that holds up, gets a short reply
and is resolved; threads that still apply stay open. Declining a finding therefore only needs a
reply with the evidence or scope boundary. PR readiness follows
[agent operations](../../CONTRIBUTING.md#pr-acceptance).

## Thread ownership

All reviewers publish as the same App identity, so each review body and each inline finding starts
with the reviewer's HTML-comment marker. A reviewer counts, re-evaluates, and resolves only threads
that carry its marker. Thermos also claims older threads that predate the markers.

Because the identity is shared, an approval from any approving reviewer satisfies the branch rule's
single required approving review; today only Thermos approves. The rule also requires every review
thread to be resolved, so an open thread from a comment-only reviewer still blocks merge.

## Repeat a review

Comment the reviewer's trigger phrase on the PR, or select **Run workflow** on the reviewer's
workflow, choose the default branch, and enter the PR number. Either posts another full review of
the current head. The PR must be open, ready, and from this repository, and the comment must come
from the owner, a member, or a collaborator. Both paths run the workflow and reviewer configuration
from the default branch. A push while a review is running cancels that run; the next run covers
both pushes.

## Setup and trust

Install the [OpenCode GitHub App](https://github.com/apps/opencode-agent) on Spotty only. The
publication step holds the App's installation token, whose pull-request write permission covers
reviews, approvals, thread replies, and resolutions; comment-versus-approve behavior is workflow
logic, not a credential restriction. Approval is computed from the output files and the live thread
state, not asserted by the agent. A finding whose inline placement the API rejects is published in
the review body instead. Reviews refuse to run, or withhold approval, when a PR has more review
threads than one API page can return.

PR changes can affect reviewer configuration, since the workflow reads it from the PR merge
revision. The agents retain shell, edit, and web tools, so treating source, threads, PR text, and
traces as untrusted input does not enforce isolation. Author replies in threads are untrusted input
to the resolution decision. This is an accepted risk for this personal repository.

After each run a summarizer, which receives no App token, condenses the review trace into the
workflow log using the shared [trace summary configuration](../../.github/agent-review/trace-summary.json).
Raw trace files are temporary and are not uploaded as artifacts.

The contributor-free model provider may use submitted public source for Meta training.

## Adding a reviewer

Create a configuration directory under `.github/` with `opencode.json` (a primary agent and its
subagents), `task.md` (the review task and the shared output contract), and the agents' prompts.
Add a caller workflow modeled on [docs-review.yml](../../.github/workflows/docs-review.yml) with a
unique marker, trigger phrase, and concurrency group. Document the reviewer's scope and limits in
its own guide and list it here and in the [documentation index](../README.md).
