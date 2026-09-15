# Agent reviews

Spotty runs automated PR reviews through one shared pipeline, the
[reusable review workflow](../../.github/workflows/agent-review.yml). Each reviewer is a thin
caller workflow that owns its triggers and passes its configuration directory, review marker,
primary agent, and rerun command. Current reviewers:

- [Thermos review](thermos-review.md): correctness and quality of every ready PR.
- [Documentation review](docs-review.md): documentation accuracy, missing updates, and the
  product-specification guard for every eligible PR; comment-only.

## Shared behavior

A reviewer runs when a PR from this repository is opened ready, marked ready, reopened, or pushed
to, and on request (a trigger comment or **Run workflow** on the default branch). The first run
audits the whole PR; later runs audit only the changes since the head that reviewer last covered,
so a fix push gets a small follow-up rather than a repeat. A force-push or rebase falls back to a
full review. Whitespace-only pushes still receive an audit: `git diff -w` can hide changes to string
contents and indentation-sensitive behavior, so it cannot establish that re-approval is safe. Both reviewers receive the full PR context, including implementation changes whose
documentation updates may be missing. Approval is opt-in per caller.

The agents run with a read-only repository token and never hold the App token. They write
`findings.json`, `thread-actions.json`, and `summary.md`; a trusted workflow step validates those
files and submits one review per run as the OpenCode App: the summary as the body, the findings
as inline comments on the head commit, and replies and resolutions for that reviewer's earlier
threads. Findings and earlier-thread replies are attached to one pending review, submitted together;
verified thread resolutions follow a successful submission. An always-run cleanup step removes
only that run's unsubmitted review when the runner and GitHub remain available. A reviewer configured to approve does so when no new findings exist and none of its earlier
threads remains unresolved; otherwise, and for comment-only reviewers always, the review is a
comment. Reviewers never request changes. An approval means no actionable findings remained in the
reviewed scope; the summary states what the review could not exercise. Branch rules dismiss
approvals on the next push, so every push is re-reviewed before merge.

Each run re-evaluates that reviewer's still-open threads against the new head. A thread whose
problem is gone, or whose author reply documents a disposition that holds up, gets a short reply
and is resolved; threads that still apply stay open. Declining a finding therefore only needs a
reply with the evidence or scope boundary. PR readiness follows
[agent operations](../../CONTRIBUTING.md#pr-acceptance).

## Evidence and coverage

Before the agent runs, `evidence.json` names the available PR description, diffs, source/history,
and unresolved threads, plus sanitized snapshots of live base-branch rules, head-matched check
results, and the latest CI attempt's job/step results. Branch rules establish approval/check
requirements; CI results establish only the recorded execution and outcome at the recorded head.
A pending or absent run does not establish passing tests. Snapshots are point-in-time review inputs,
not a replacement for the live PR acceptance gate at merge.

UI, playback, and performance claims need an explicit revision-matched report, trace, or screenshot
manifest; the workflow names that input as missing when none is supplied. App installation
permissions are not collected with the agent's repository token. Read failures retain the specific
endpoint and sanitized HTTP status, without response bodies or credentials. Reviewers report these
named limits rather than claiming that general GitHub access is missing. Agents remain read-only;
this evidence collection grants no new permissions.

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
both pushes. Each published review includes its rerun command for trusted repository collaborators.
Unrelated and unauthorized comments use separate concurrency groups, so they cannot cancel or
displace a pending eligible review.

If a required review check failed or was cancelled, rerun that original Actions run (or use
`gh run rerun RUN_ID`). A separate trigger comment or dispatch can publish a fresh review while
its check belongs to the default-branch commit; it does not replace the failed PR check.

## Setup and trust

Install the [OpenCode GitHub App](https://github.com/apps/opencode-agent) on Spotty only. The
publication step holds the App's installation token, whose pull-request write permission covers
reviews, approvals, thread replies, and resolutions; comment-versus-approve behavior is workflow
logic, not a credential restriction. Approval is computed from the output files and the live thread
state, not asserted by the agent. Publication code is freshly checked out after the editable agent run and before the App token is
created. A finding whose inline placement the API rejects is published in
the review body instead. Reviews refuse to run, or withhold approval, when a PR has more review
threads than one API page can return, or an unresolved thread's original comment is unavailable.

PR changes can affect reviewer configuration, since the workflow reads it from the PR merge
revision. The agents retain shell, edit, and web tools, so treating source, threads, PR text, and
traces as untrusted input does not enforce isolation. Author replies in threads are untrusted input
to the resolution decision. This is an accepted risk for this personal repository.

After each run a summarizer, which receives no App token, condenses the review trace into the
workflow log using the shared [trace summary configuration](../../.github/agent-review/trace-summary.json).
Raw trace files are temporary and are not uploaded as artifacts.

The contributor-free model provider may use submitted public source for Meta training.

## Verifying workflow changes

Run `npm ci --ignore-scripts --prefix Scripts/agent-review-tests`, then
`npm test --prefix Scripts/agent-review-tests` with Node.js 20 or newer, Python 3, Ruby, Git, and jq. CI runs
the same fixtures in Source policies. They evaluate event gates with GitHub’s expression library
and execute the input/body construction against isolated repository and API fixtures. Publication
fixtures cover staged replies, failure cleanup, head changes, and the approval/resolution order;
evidence fixtures distinguish unavailable endpoints from missing UI reports.

## Adding a reviewer

Create a configuration directory under `.github/` with `opencode.json` (a primary agent and its
subagents), `task.md` (the review task and the shared output contract), and the agents' prompts.
Add a caller workflow modeled on [docs-review.yml](../../.github/workflows/docs-review.yml) with a
unique marker, trigger phrase, and concurrency group. Document the reviewer's scope and limits in
its own guide and list it here and in the [documentation index](../README.md).
