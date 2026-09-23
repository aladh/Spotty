# Agent reviews

The [shared workflow](../../.github/workflows/agent-review.yml) runs two reviewers:
[Thermos](thermos-review.md) checks correctness and quality;
[Documentation review](docs-review.md) checks documentation and product contracts without approving.
Each caller owns its configuration, marker, and trigger command.

## Shared behavior

Reviews run when same-repository PRs become ready, reopen, receive a push, or receive a trusted
request. The first run covers the whole PR; later runs inspect changes since the reviewer's last
head using full PR context. Rebases and force-pushes require full review. Whitespace-only changes
still require review.

Every push dismisses approval and triggers review. Reviewers recheck their open threads and reply
before resolving fixed findings or supported dispositions. Decline a finding with evidence or a
scope explanation. Approval requires no new findings or unresolved owned threads; otherwise the
reviewer comments, never requests changes. [PR acceptance](../../CONTRIBUTING.md#pr-acceptance)
governs merge readiness.

## Evidence and coverage

`evidence.json` snapshots PR context, branch rules, head-matched checks, and the latest CI attempt.
It records observed requirements and execution, not current merge readiness; pending runs prove no
passing tests. Read failures expose only the endpoint and sanitized status, without response bodies
or credentials.

The collector reads the latest completed, head-matched CI attempt's `acceptance-evidence-RUN-ATTEMPT`
artifact against the [head manifest](../../Tests/BrowsingHarness/Scenarios/manifest.json). Coverage
requires passing nested outcomes, matching identities/digests, clean unchanged source, and the
complete scenario set. Checkout and PR-head revisions remain separate because CI may test a merge
revision. Old, expired, malformed, dirty, or mismatched evidence cannot establish coverage. Artifact
reads are bounded and never execute or extract ZIP contents.

Corpus summaries prove synthetic state assertions only. Signed Demo isolation, visual fidelity,
live playback, and performance need their own revision-matched evidence. Review summaries name
missing coverage; app installation permissions are not collected and evidence grants no permissions.

## Thread ownership

Reviewers share one App identity; per-reviewer markers delimit thread ownership. Thermos also owns
legacy unmarked threads and is currently the only approver. Every thread must be resolved,
including documentation-review findings.

## Repeat a review

Use the review's trigger command or dispatch its default-branch workflow with the PR number.
Both request a full review using default-branch configuration. The PR must be open, ready, and
same-repository; trigger comments require an owner, member, or collaborator. Pushes supersede
active reviews; unrelated or unauthorized comments cannot displace them.

For a failed or cancelled required check, use `gh run rerun RUN_ID` on that Actions run. Trigger
comments and dispatches may attach checks to the default-branch commit and cannot replace a failed
PR check.

## Setup and trust

Install the [OpenCode GitHub App](https://github.com/apps/opencode-agent) on Spotty only. Agents get
a read-only repository token; freshly checked-out publication code validates outputs and uses the
App token for reviews, replies, and resolutions. Comment-only behavior is workflow logic, not a
credential restriction. Resolutions follow successful submission; cleanup removes only that run's
unsubmitted review when GitHub and the runner remain available.

Incomplete or changing PR/thread history prevents approval and resolution. Publication rechecks
history after submission and stops remaining resolutions on changes. These snapshots are not atomic.
The [shared workflow](../../.github/workflows/agent-review.yml) owns exact safeguards and output schemas.

PR-triggered runs use configuration from the PR merge revision. Agents retain shell, edit, and web
tools; untrusted-input instructions do not enforce isolation. Author replies are untrusted too.
This is an accepted risk for this personal repository. A summarizer without the App token writes
workflow logs; raw traces remain temporary and are not uploaded. The contributor-free provider may
use submitted public source for Meta training.

## Verifying workflow changes

With Node.js 20+, Python 3, Ruby, Git, and jq:

```bash
npm ci --ignore-scripts --prefix Scripts/agent-review-tests
npm test --prefix Scripts/agent-review-tests
```

Local and CI Source policies run this suite through [script-test discovery](../../Scripts/script_tests.py).
The tests own event, publication, history, cleanup, and evidence cases.

## Adding a reviewer

Create `.github/REVIEWER/` with `opencode.json`, agent prompts, and `task.md` using the shared output
contract. Model the caller on [docs-review.yml](../../.github/workflows/docs-review.yml), with a
unique marker, trigger phrase, and concurrency group. Document its scope and limits in a guide
linked here and in the [documentation index](../README.md).
