# Thermos review

The advisory workflow reviews same-repository PRs when opened ready or marked ready.
Pushes do not trigger reviews. A marked summary from `opencode-agent[bot]` or the
historical `github-actions[bot]` identity skips repeated automatic reviews.

Thermos launches independent correctness and quality subagents in parallel. The parent
uses `gh` to post actionable inline findings and a marked summary comment. Findings must
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
there is no writer-only actor check or comment-command trigger.

## Identity and permissions

Install the [OpenCode GitHub App](https://github.com/apps/opencode-agent) on Spotty only.
The workflow exchanges a GitHub Actions OIDC token with
`https://api.opencode.ai/exchange_github_app_token`, using audience
`opencode-github-action`, and passes the App token to `gh` during review. No App private
key or additional repository secret is required. Exchange failure fails the job without
falling back to the Actions identity.

The App has broader write grants: contents, issues, pull requests, workflows, repository
secrets, and organization secrets when installed on an organization. Workflow permissions
limit the Actions token, not the App token. The exchange does not narrow installation
permissions. The reviewer can use its token through shell commands; comment-only behavior
is prompt policy, not a credential restriction. The App remains subject to Spotty's
main-branch rules and has no configured bypass. Approval settings are unchanged.

Eligibility lookup uses the read-only Actions token. App authentication happens after
installation and checkout. Installation, review, and trace summarization clear OIDC
request credentials from their environments. Authentication calls have bounded timeouts and distinct errors.
An always-run cleanup step revokes the App token; cleanup failure warns without failing
a published review. Forced runner termination can prevent cleanup, in which case the
token expires normally.

## Runtime and limits

OpenCode remains pinned to 1.18.29, using `opencode/muse-spark-1.3-contributor-free` at
`xhigh`, with no fallback. The contributor-free provider may use submitted public source
for Meta training; availability and model terms remain provider-controlled.

Reviewer configuration comes from the workflow revision in a separate checkout.
For `pull_request`, that revision is the PR merge commit; this no longer has the
base-workflow trust boundary of `pull_request_target`. Manual runs use the default-branch
workflow revision. The PR source is checked out at the selected head SHA with full
history. Pure mode and disabled project configuration prevent automatic discovery of
candidate configuration, plugins, and skills. Shell, filesystem, edit, websearch, and
webfetch access remain available; web content is untrusted review data.

Raw review output stays in a temporary runner log that disappears with the runner. After
a successful or failed review, a separate trace-summary agent reads that log and exported
auditor sessions, then summarizes the review and assesses its thoroughness in the
workflow log, using its judgment about inspection depth and useful detail. The summarizer
receives no App token and treats trace contents as untrusted data. No raw trace artifact
is uploaded, and session sharing remains disabled.

Publication is left to Thermos; there is no custom publisher or enforced revision
recheck. Inline findings can remain after an interrupted review, and a retry may duplicate
them when no marked summary was posted. Automatic retries are not configured. This is
not a required check or approval gate. The job times out after 20 minutes.

The workflow uses runner ripgrep when available and installs it with apt otherwise.
Web search is enabled with `OPENCODE_ENABLE_EXA=1`; no additional search credential is
configured.
