# Thermos review

The advisory workflow reviews same-repository PRs when opened ready or marked ready.
Pushes do not trigger reviews. A marked summary from `opencode-agent[bot]` or the
historical `github-actions[bot]` identity skips repeated automatic reviews.

Thermos launches independent correctness and quality subagents in parallel. The parent
uses `gh` to post actionable inline findings. The official action posts the final marked
summary for automatic writer-triggered runs; manual runs and CLI fallback runs let the
parent post the summary through `gh`. Findings must
be introduced or made reachable by the PR; omit informational notes and unrelated
follow-ups. Conclusions state coverage limits and rely on inspected evidence rather
than auditor agreement or declarations that the PR is safe to merge.

The original Cursor Thermos rubrics and MIT license live in
[.github/thermos-review](../../.github/thermos-review), recovered from
[PR #291](https://github.com/aladh/Spotty/pull/291). Their prompts load directly through
`{file:...}` references. The parent explicitly runs as `thermos`; both auditor agents
retain their original tools and permissions.

## Repeat a review

Select **Run workflow** on **Thermos review**, choose the default branch, and enter the
PR number, or run:

```bash
gh workflow run thermos-review.yml --ref main -f pr_number=287
```

Manual runs use the current base/head SHAs and bypass summary deduplication, posting
another review. Only open, ready, same-repository PRs are eligible. Manual runs from
other branches are skipped. Bot-authored PRs remain eligible for automatic reviews;
actors rejected by the action's writer check use the existing CLI path. There is no
comment-command trigger.

## Identity and permissions

Install the [OpenCode GitHub App](https://github.com/apps/opencode-agent) on Spotty only.
The workflow exchanges a GitHub Actions OIDC token with
`https://api.opencode.ai/exchange_github_app_token`, using audience
`opencode-github-action`, and passes the App token to `gh` during review. The official action receives that same
App token as `GITHUB_TOKEN` with `use_github_token: true`; this selects the supplied App
token, not the built-in Actions identity. No App private
key or additional repository secret is required. Exchange failure fails the job without
falling back to the Actions identity.

The App has broader write grants: contents, issues, pull requests, workflows, repository
secrets, and organization secrets when installed on an organization. Workflow permissions
limit the Actions token, not the App token. The exchange does not narrow installation
permissions. The reviewer can use its token through shell commands; comment-only behavior
is prompt policy, not a credential restriction. The App remains subject to Spotty's
main-branch rules and has no configured bypass. Approval settings are unchanged.

Eligibility lookup uses the read-only Actions token. App authentication happens after
the pinned CLI installation and checkout. That installation and the review entrypoint
clear OIDC request credentials from their environments. The official composite action's
setup steps inherit the App token, including its upstream installer/cache machinery. Authentication calls have bounded timeouts and distinct errors.
An always-run cleanup step revokes the App token; cleanup failure warns without failing
a published review. Forced runner termination can prevent cleanup, in which case the
token expires normally.

## Runtime and limits

The official action is pinned to its v1.18.29 commit. A small `BASH_ENV`/PATH adapter
routes its `opencode github run` invocation to the independently installed CLI, changes
to the source checkout, enables pure mode, and retains hidden output. The action's own
installer/cache can change PATH but cannot select the runtime used for review. It is
also given `VERSION=1.18.29` for its installer. The adapter does not replace GitHub mode
with an ordinary CLI run.

OpenCode remains pinned to 1.18.29, using `opencode/muse-spark-1.3-contributor-free` at
`xhigh`, with no fallback. The contributor-free provider may use submitted public source
for Meta training; availability and model terms remain provider-controlled.

Reviewer configuration comes from the workflow revision in a separate checkout.
For `pull_request`, that revision is the PR merge commit; this no longer has the
base-workflow trust boundary of `pull_request_target`. Manual runs use the default-branch
workflow revision. The PR source is initially checked out at the selected head SHA with full
history. The official action subsequently fetches and checks out the current PR branch
for automatic runs; that fetch can advance the reviewed head and limit history depth. Pure mode and disabled project configuration prevent automatic discovery of
candidate configuration, plugins, and skills. Shell, filesystem, edit, websearch, and
webfetch access remain available; web content is untrusted review data.

Review output stays in a temporary runner log that disappears with the runner. There
is no separate trace-summary invocation or uploaded trace artifact. Session sharing is
disabled. Removing the trace summary does not remove either auditor.

Inline publication is left to Thermos; there is no custom publisher or enforced revision
recheck. The official action adds a run-link footer to automatic summaries and can post
an error comment on failure. Its automatic Git pushes are disabled with an unusable
origin push URL. If the action tries to push after modifying the checkout, the run fails
instead of publishing code; scratch work should stay in the runner temporary directory.
Manual action runs may create an ephemeral local branch but still target the requested
PR through the prompt and `gh`. Inline findings can remain after an interrupted review, and a retry may duplicate
them when no marked summary was posted. Automatic retries are not configured. This is
not a required check or approval gate. The job times out after 20 minutes.

The workflow uses runner ripgrep when available and installs it with apt otherwise.
Web search is enabled with `OPENCODE_ENABLE_EXA=1`; no additional search credential is
configured.

Adapter checks: `python3 -m unittest discover -s Tests/Automation -p 'test_*.py'`.

## Trial differences requiring approval

The official-action path can refresh the PR head and shorten history, adds its own
summary footer and failure comments, and fails if its automatic push path is reached.
Its setup also receives the supplied App token. These are proposed tradeoffs for this
trial, not permission to change the review behavior further. The direct CLI path remains
for unsupported actors so bot PRs do not silently lose automatic reviews.
