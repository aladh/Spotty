# Agent reviews

The [shared workflow](../../.github/workflows/agent-review.yml) runs two reviewers:
[Thermos](thermos-review.md) checks correctness and quality;
[Documentation review](docs-review.md) checks documentation and product contracts without approving.
Each caller owns its triggers, configuration directory, marker, primary agent, and rerun command.

## Shared behavior

Reviews run for same-repository PRs opened ready, marked ready, reopened, or pushed to, and on
trusted requests. Both reviewers receive the full PR context, including code whose documentation
may be missing. The first run covers the whole PR; subsequent runs cover changes since that
reviewer's last head. Rebases and force-pushes fall back to full review. Whitespace-only changes
still need review because whitespace can affect strings and behavior.

Agents use a read-only repository token, never the App token. A trusted publication step validates
`findings.json`, `thread-actions.json`, and `summary.md`, then submits findings and earlier-thread
replies together as one OpenCode App review. Verified resolutions follow successful submission.
Always-run cleanup removes only that run's unsubmitted review when GitHub and the runner remain
available. Rejected inline placements become review-body findings.

An approving reviewer approves only when no new findings or unresolved owned threads remain;
otherwise it comments. Reviewers never request changes. Approval covers the reviewed scope, with
unexercised behavior named in the summary. Every push dismisses approval and triggers review again.
Each run rechecks its open threads: fixed issues or evidence-backed dispositions receive a reply
and resolution; applicable findings stay open. Decline a finding by replying with evidence or the
scope boundary. [PR acceptance](../../CONTRIBUTING.md#pr-acceptance) remains the merge gate.

## Evidence and coverage

`evidence.json` identifies PR text, diffs, source/history, unresolved threads, sanitized live branch
rules, head-matched checks, and the latest CI attempt's job/step results. These snapshots establish
recorded requirements and execution, not current merge readiness. Pending or absent runs never
establish passing tests.

UI, playback, and performance claims need revision-matched reports, traces, or screenshot manifests;
the workflow identifies missing evidence. App installation permissions are not collected. Read
failures report the endpoint and sanitized HTTP status without response bodies or credentials.
Reviewers name these limits precisely; evidence collection grants no new permissions.

## Thread ownership

All reviewers share one App identity. A unique HTML-comment marker on each review and finding
limits which threads a reviewer can count, reassess, or resolve. Thermos also owns legacy unmarked
threads. Any approving reviewer can satisfy the single-approval branch rule; currently only Thermos
approves. Every thread must be resolved, including those from comment-only reviewers.

## Repeat a review

Use the reviewer's trigger comment or **Run workflow** on its default-branch workflow with the PR
number. Both run the default-branch workflow/configuration and request a full review of the current
head. The PR must be open, ready, and from this repository; trigger comments require an owner,
member, or collaborator. Each published review includes its command.

A push cancels an active review; the next run covers both pushes. Unrelated or unauthorized comments
have separate concurrency groups and cannot displace eligible runs.

For a failed or cancelled required check, rerun the original Actions run (`gh run rerun RUN_ID`).
A trigger comment or dispatch may publish a review whose check belongs to the default-branch
commit; it does not replace the failed PR check.

## Setup and trust

Install the [OpenCode GitHub App](https://github.com/apps/opencode-agent) on Spotty only. Its
installation token permits review publication, approval, replies, and resolution; comment-only
behavior is workflow logic, not a credential restriction. Publication code is freshly checked out
after the agent runs and before creating that token. Approval derives from validated outputs and
live thread state, never the agent's assertion.

Too many threads for one API page, missing original comments, or changed/incomplete reviewed
histories prevent approval and resolution. Publication compares live history before submission and
again before resolution, including threads resolved by others and excluding only its own staged
replies. Changes detected after submission stop remaining resolutions. These separate GitHub
requests provide snapshots, not an atomic transaction.

PR-triggered runs read reviewer configuration from the PR merge revision. Agents retain shell,
edit, and web tools: treating source, PR text, threads, and traces as untrusted does not enforce
isolation. Author replies are also untrusted resolution input. This is an accepted risk for this
personal repository.

A summarizer without the App token condenses the trace into workflow logs using the
[shared configuration](../../.github/agent-review/trace-summary.json). Raw traces are temporary and
not uploaded. The contributor-free model provider may use submitted public source for Meta training.

## Verifying workflow changes

With Node.js 20+, Python 3, Ruby, Git, and jq:

```bash
npm ci --ignore-scripts --prefix Scripts/agent-review-tests
npm test --prefix Scripts/agent-review-tests
```

Local and CI Source policies run this same suite through [script-test discovery](../../Scripts/script_tests.py).
The fixtures exercise event admission, input construction,
publication ordering, failure cleanup, history changes, and missing evidence against isolated Git
and API fixtures. Exact cases belong in the tests.

## Adding a reviewer

Create `.github/REVIEWER/` with `opencode.json`, agent prompts, and `task.md` using the shared output
contract. Model the caller on [docs-review.yml](../../.github/workflows/docs-review.yml), with a
unique marker, trigger phrase, and concurrency group. Document its scope and limits in a guide
linked here and in the [documentation index](../README.md).
