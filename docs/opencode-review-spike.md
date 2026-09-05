# Thermos-style OpenCode advisory reviews (#233)

PR #268 tests a replacement for Cursor Thermos alongside CodeRabbit. It remains advisory and
confined to the same-repository `codex/opencode-review-spike` branch. It does not change the
[PR acceptance criteria](../CONTRIBUTING.md#automated-pr-acceptance), protections, or either existing
reviewer's role. #233 stays open for the adoption decision.

## Run and inspect

Push the trial PR or rerun **all jobs** in `OpenCode advisory review`. The workflow has two jobs:

1. `Source-aware OpenCode review` tests the reviewer, builds immutable source snapshots, runs
   independent correctness/security and maintainability audits in parallel, then synthesizes their
   findings. Each model process runs without GitHub credentials and returns validated JSON.
2. `Publish advisory findings` uses a scoped Actions token in a separate runner,
   checks that the PR is still open at the expected base/head, and updates one advisory overview
   plus inline diff comments as `github-actions[bot]`. Only this job has `pull-requests: write`;
   neither job has OIDC access.

The comment lists active findings with stable IDs and links to exact source revisions, plus
explicit resolution reasons for previously open findings. Each finding also appears on the diff.
Unchanged findings update their own bot thread; moved findings receive a current anchor, and
explicitly resolved findings close only the corresponding OpenCode-owned thread. Resolution
reasons are model assessments, not proof of correctness. Human and other reviewers' threads are
never changed. The workflow never submits `APPROVE` or `REQUEST_CHANGES`. A green run means a validated advisory response was published,
not that the PR is correct.

`opencode-review-<run>-<attempt>` contains the validated report for 14 days. Diagnostic events
are retained separately for 7 days. Rerun all jobs after a transient failure: a publisher-only
rerun deliberately cannot reuse an artifact from a different attempt.

## Thermos review process

The rubrics are vendored verbatim from [Cursor Thermos](https://github.com/cursor/plugins/tree/93b00b89ef425a9c1bac0d0b317dfc49c930ac99/thermos),
pinned to commit `93b00b89ef425a9c1bac0d0b317dfc49c930ac99`, under
[`.github/review/thermos/`](../.github/review/thermos/). Cursor's MIT license is retained alongside
correctness, code-quality and orchestration references. There is no runtime download of prompts.

Like `/thermos`, this workflow performs two independent audits of the same source/diff context:

- **Correctness/security:** bugs, cross-module breakage, developer setup regressions, feature-gate
  leaks, intended changes and calibrated severity. Findings require completed source investigation.
- **Maintainability:** substantial simplification, branching growth, abstractions, typed contracts,
  canonical layers, needless sequential work and non-atomic updates. The rubric explicitly checks
  files growing from below 1,000 lines to above that threshold and rejects low-value cosmetic nits.

After both finish, a separate synthesis pass deduplicates findings, weighs independent agreement,
resolves disagreements against source, and produces one prioritized report. If the correctness
pass found P1/P2 risks, a read-only workflow step first gathers bounded PR discussion for the
synthesis pass. Borrowed findings must be verified and attributed by author and comment URL;
other reviewers' claims are not independent corroboration. Neither initial audit sees that
material or the other audit's result.

The adaptation uses parallel isolated CLI processes instead of Cursor's Task subagents, all on
Muse contributor-free with `xhigh`. The checked-in common prompt retains the review-only tool
limits and structured finding lifecycle. It overrides upstream instructions to invoke CLI tools,
edit files or issue approval; the upstream quality bar remains review guidance. Compared with
Cursor's interactive workflow, GitHub discussion is gathered by orchestration, publication remains
one advisory overview with tracked diff comments, and failed passes stop publication. This is process/rubric parity, not a
claim that Muse matches Cursor's review quality.

## Source access and incremental behavior

The model can read, glob and search `source/` at the PR head and `before/` at the comparison
revision. Both bounded diffs are supplied directly to every model pass as untrusted source data
(identical full/incremental diffs are included once), so seeing changes does not depend on an
optional file-read tool call. Raw Git blobs are used, so candidate export-ignore attributes cannot hide source and
symlinks/submodules are never followed. The full PR diff remains available. Prior OpenCode findings
and bounded event-snapshot PR intent are supplied as untrusted context. Other reviewers' discussion
is available only to the later synthesis pass under the Thermos condition above.

A prior result narrows the review to new commits only when its repository, PR, base SHA and
reviewer-policy digest match, its head is an ancestor, and its recorded workflow run/attempt
completed successfully. A policy/base/history change forces full coverage while preserving findings
from the latest verified same-PR result for reassessment. The model must still recheck **every**
previously open finding. Each ID
must be retained or explicitly resolved; omissions, unknown IDs and duplicate IDs fail validation.
New findings receive deterministic IDs, and the publisher updates its existing comment instead
of posting duplicate overview comments on each push. Inline comments use the same finding IDs;
source locations must be valid right-side anchors in the full PR diff.

Missing/incompatible baselines, changed base commits, rewritten history, and changes to the
reviewer implementation, prompt, workflow or pins cause a full review. Rerunning the same head
also performs a full review and rechecks previous findings. Failed or stale runs never become
incremental baselines. Publication checks base/head immediately before and after the comment
write, and before inline mutations. GitHub cannot atomically bind all comment writes to a PR SHA;
a racing push or API failure can leave a partial set of explicitly revision-bound comments. The
run fails, retries reconcile owned finding IDs, and the overview is updated only after inline
publication succeeds, so incomplete state is not reused as a successful baseline.

## Boundaries and limits

The [workflow environment](../.github/workflows/opencode-spike.yml) owns the CLI version, release
checksum, free model and `xhigh` reasoning selection. The CLI release checksum is verified; there
is no provider key or paid fallback. The model process receives a small environment allowlist
without GitHub, OIDC, Actions runtime or local authentication tokens. Its working directory is a
source snapshot with no `.git` directory. Shell, writes, network tools, external directories,
subagents, skills, project configuration, external plugins, LSP, formatting and session sharing
are disabled. Only read/search tools are allowed; the CLI still contacts the model provider.

The initial availability spike tested OpenCode Agent with access only to `aladh/Spotty`. The App
was subsequently uninstalled: this CLI-based workflow needs neither its installation nor its broad
token or OIDC.
The separate control publisher uses the short-lived Actions token with `contents: write` and
`pull-requests: write`; the model runner has read-only repository permissions and receives no token
in its subprocess environment. No GitHub App installation is required. This is an owner-controlled
trial: orchestration code comes from this PR. Before enabling arbitrary contributors or making it
a required gate, move orchestration and policy to a protected revision.

Discussion collection reads at most three pages per kind, retaining the newest 20 records within
that bounded history and at most 2,000 characters per body. Truncation and omitted records are
recorded for synthesis; this is not an exhaustive scan of a long PR history. Inline publication
currently requires a right-side hunk anchor in a text file present at the head; removed-only files
and non-text changes remain a coverage limitation.

Each source tree is bounded to 25 MB of eligible blobs, individual files to 1 MB, and each diff
to 300 KB. Oversized diffs/snapshots fail rather than silently truncate. Non-text, oversized files,
symlinks and submodules omitted from snapshots are explicitly listed in the input and comment.
Findings must name an existing line in a text file changed by the PR. Each model pass has a
ten-minute budget and 30 steps; the two independent audits run concurrently. The review job has
a 25-minute limit including synthesis and setup. Provider errors, incomplete output, invalid JSON, missing finding dispositions,
invalid locations and oversized comments fail visibly without replacing the prior comment.

The free contributor offering is temporary and permits using prompts/completions to train future
Meta models. Use public source only: no account data, credentials, diagnostic exports or confidential
code. Runner usage is separate from model pricing. Source access and structural validation reduce
some errors; they do not prove findings or resolutions are semantically correct.

## Evidence and adoption

The initial [App availability run](https://github.com/aladh/Spotty/actions/runs/33947896871) succeeded
with Muse `xhigh`. A local synthetic Swift bounds-check review found the seeded regression at
reported cost zero. The first diff-only PR response confidently misidentified the official upstream
and the exported prompt; its [disposition](https://github.com/aladh/Spotty/pull/268#issuecomment-5549761593)
is retained as a quality warning. Later diff-only responses had seen other reviewers' comments and
are not independent benchmarks.

The first source-aware [Actions run](https://github.com/aladh/Spotty/actions/runs/33950084958)
passed on `d2302e1`: the model made nine source reads in 126 seconds, returned a validated
no-findings result, and the separate scoped-token publisher posted the
[advisory comment](https://github.com/aladh/Spotty/pull/268#issuecomment-5550007223).
All 14 deterministic reviewer tests and normal PR CI passed. Separate local source-aware fixtures
found a seeded Swift bounds regression, then retained its finding ID in an explicit resolution
when the next revision fixed it. These are integration checks, not a review-quality benchmark.

After uninstalling the App, the [incremental run](https://github.com/aladh/Spotty/actions/runs/33950370819)
passed on `55e8853`. Its report selected `d2302e1` as the verified baseline, and the publisher updated
the same comment ID. The model made 14 reads in 156 seconds and reported no findings. This proves
baseline selection and comment reuse without the App; it does not demonstrate a latency saving.

The Thermos adaptation passed a local source-only fixture with both a bounds-check crash and a
60-branch structural regression: the independent passes found their respective issues and synthesis
kept both. Early synthesis retained an unsupported future-edit-count claim; an explicit
counterexample check removed that claim in the revised run. The fixed snapshot then produced zero
active findings and explicit resolutions for both original IDs across all three passes. This
fixture is an integration/calibration check, not a representative accuracy benchmark. Focused
standard-library tests cover lifecycle, parallel isolation, validation, and owned inline publication;
the live GitHub GraphQL thread query was also verified read-only.

The first [two-audit Actions run](https://github.com/aladh/Spotty/actions/runs/33951942958)
passed on `80d9991`, as did normal PR CI. Its independent quality audit identified duplicated
validation contracts; synthesis retained that P3 finding and the publisher updated the overview
and created a [real inline finding](https://github.com/aladh/Spotty/pull/268#discussion_r3939838965).
This exercises actual GitHub diff publication, beyond mocked API tests.

The [follow-up run](https://github.com/aladh/Spotty/actions/runs/33952672829) on `2ab3f3a`
retained that ID through a policy-triggered full review and correctly reported it fixed.
Its traces show concurrent audit starts less than half a second apart, followed by synthesis
reading both audit JSON files. Publication exposed a GraphQL/REST bot-login mismatch: the overview
updated, but the inline thread stayed open. The corrected publisher requires GraphQL `Bot` type
and login `github-actions`; REST retains `github-actions[bot]`. Running the corrected sync locally
against that real validated report updated and resolved the thread through GitHub's API. This
local recovery is separate from Actions evidence. The same trace audit motivated supplying diffs
directly rather than assuming the model would open them.

A separate local fixture adapted the missed-border-pixel bug from PR #261 without supplying
the historical review or its answer. The correctness audit found the bug and the quality audit
reported no structural issue; a Swift probe independently confirmed that the transparent pixel
was accepted. Initial synthesis inflated severity to P1. Clarifying that P1 requires a traced
major consequence yielded P2 while retaining the same bug. Restoring the exact scan then yielded
zero active findings and an explicit resolution of that original ID. This is one reduced historical case,
not evidence of parity with Cursor or a representative false-positive rate.

Before making it authoritative, evaluate known bugs and clean changes without
other reviewers' answers, measure false positives and latency, and implement revision-bound
approval/check publication using trusted orchestration. Do not promote
this advisory trial to a required review gate solely because its Actions jobs pass.

## Native OpenCode subagent experiment

A local trial of pinned OpenCode's native `task` tool created two child sessions under one parent.
Background tasks were unsuitable for the current CLI invocation: the parent emitted a launch
acknowledgment and stopped before synthesizing. A fresh trial issued two foreground task calls
together. The child sessions were created 12 ms apart, completed independently, and the parent
combined the seeded correctness and structural findings. Exported parent/child sessions confirmed
Muse contributor-free with `xhigh`; the children used only read tools and created no nested tasks.
The fresh input contained source, before, diffs and metadata, with no previous audit answers.

This establishes native delegation and synthesis, using reduced review prompts on one synthetic
fixture. It does not establish review-quality or latency superiority over the full Thermos rubrics.
The CI implementation still uses the independently validated audit processes above. Adopting native
delegation should validate completed child outputs and exports, reject early/background-only
completion, preserve finding IDs, and retain the credential-free boundary around conditional
post-audit discussion. Configure each child's permissions explicitly: parent-agent permissions do
not by themselves constrain children. Either inherit both model and variant, or pin both on each
child; setting only a child model suppresses parent variant inheritance in this OpenCode version.

Official references: [GitHub integration](https://opencode.ai/docs/github/),
[model/privacy terms](https://opencode.ai/docs/zen/),
[tool permissions](https://opencode.ai/docs/permissions/), and
[GitHub comment permissions](https://docs.github.com/en/rest/issues/comments).

## OpenCode 2 and direct GitHub MCP pilot

A follow-up full-rubric native fixture completed both foreground audits and parent synthesis with
Muse contributor-free `xhigh`. OpenCode 1.18.29 took 68.92 seconds; official OpenCode 2 beta
`0.0.0-beta-19151` took 36.92 seconds and retained the same seeded correctness and quality findings.
The parent prompts named the seeded bug patterns, so this checks runtime/delegation compatibility,
not independent bug discovery or review accuracy. The timing is one sample, not a benchmark. V2 uses a private `--standalone`
server, a model selector containing `#xhigh`, and native `subagent` calls. Its session export outcome,
rather than V1's terminal `step_finish` event, is the completion evidence.

A separate [local direct-MCP trial](https://github.com/aladh/Spotty/pull/268#pullrequestreview-5121596304)
used two independent full-rubric native V1 audits. The parent verified PR revisions and submitted an
advisory COMMENT review through the official GitHub MCP server. The custom Python publisher did not
post that review. Both audits returned no findings, so this run did not exercise MCP inline comments.
The local review used the existing authenticated GitHub identity; it is not Actions-token evidence.

The additional `opencode-mcp-spike.yml` workflow tests native delegation and direct MCP publication
on this owner-controlled spike branch. Only four server tools are exposed: PR reads, immutable file
reads, pending-review inline comments, and review publication. Children receive independent full
Thermos rubrics and attached diffs, with local read/search tools; the parent handles corroboration
and publication. Runtime traces and live GitHub postconditions record what actually happened.
The experiment remains advisory. Postconditions detect violations after calls; they do not make
GitHub's consolidated review tool technically incapable of approving or changing review threads.
No approval gate or trusted-fork claim follows from a successful experimental run.

The bounded diff allowance is 300 KB per logical input so both implementations can review this
comparison PR in full. Oversized inputs still fail explicitly; identical full/delta diffs are
attached once. The earlier evidence used the former 200 KB bound.

V2 integration references: [CLI private servers](https://opencode.ai/v2/docs/cli),
[MCP configuration](https://opencode.ai/v2/docs/mcp-servers), and the
[official GitHub MCP server](https://github.com/github/github-mcp-server/tree/v1.12.0).

A clean V2 runtime initially could not resolve the model because its default catalog endpoint
returned HTTP 403 in this environment. Explicitly loading the public models.dev catalog restored
Muse contributor-free `xhigh` without account credentials. The trial now checks in only the selected provider/model entry in `.github/review/models.json`,
captured from models.dev on 2026-09-05, rather than resolving an unreviewed live catalog.


The [first V2 Actions trial](https://github.com/aladh/Spotty/actions/runs/33975552723) completed both
native audits but did not publish: its parent could not see MCP tools under the deny-by-default
policy. Isolated probes proved that the beta connects to MCP and can make an actual GitHub read
with broad permissions, but the tested scoped rules did not preserve that capability. V1 succeeded
with the same read-only MCP server and a deny-by-default permission policy. The current native MCP
workflow therefore retains pinned V1.18.29. The guided V2 timing result does not outweigh this
permission regression; reconsider V2 when the intended tool policy passes the same integration test.

The MCP launcher alone reads the short-lived token from private runtime storage; the OpenCode
process environment contains no GitHub token. Untrusted prompt text is escaped against config
`{env:...}` and `{file:...}` expansion. Children require completed, independent model-matched
exports with actual JSON reports; the parent trace and live GitHub review must agree on the marked
overview and inline comments. These remain post-run evidence checks, not a pre-call authorization
proxy. Cancellation is disabled within a PR's publishing concurrency group to reduce orphaned
pending reviews.

The two implementations are a temporary comparison inside issue #233. Keep their responsibilities
separate during the experiment, share path/hunk validation, and select one orchestration path before
promoting a general reviewer; do not maintain two authoritative reviewers implementing the same
contract. The MCP trial currently performs full reviews and creates a marked review per run. It has
not replaced the control's incremental baseline or stable finding-resolution lifecycle.


The [native V1 Actions run](https://github.com/aladh/Spotty/actions/runs/33977771271) passed on
`b21dc9a`: both Muse `xhigh` children completed, starting 34 ms apart, and the parent verified
candidates through immutable MCP file reads before posting the
[advisory review](https://github.com/aladh/Spotty/pull/268#pullrequestreview-5122040155).
The root trace contains two native tasks, seven MCP reads and one MCP review write. No inline
findings were warranted; MCP inline publication remains unexercised live. Native execution took
about 284 seconds on this PR; it is not a controlled latency benchmark.

The same-head control run exposed a separate thread-resolution permission failure after creating a
replacement inline finding. GitHub documents that
[`resolveReviewThread` may require contents-write for installation tokens](https://github.com/github/gh-aw/issues/35726).
Only the control's separate publisher job receives that permission; no model runs there and checkout
credentials are not persisted. The MCP trial still uses contents-read/PR-write and does not resolve
threads. This is another constraint to handle before introducing an authoritative general reviewer.

The [control run on `461119c`](https://github.com/aladh/Spotty/actions/runs/33978878101)
passed with the isolated publisher permission and automatically resolved the superseded inline
thread. Both review workflows and normal CI passed on that commit. The next implementation PR
should select one orchestration path and remove the other before enabling reviews beyond this
spike branch; the parallel control is not intended to survive that promotion.
