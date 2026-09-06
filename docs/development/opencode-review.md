# OpenCode Thermos review

The advisory workflow uses the [official OpenCode GitHub action](https://opencode.ai/docs/github/)
with `pull_request` events when a same-repository PR opens ready or becomes ready.
Pushes do not trigger reviews. A marked summary from `opencode-agent[bot]` or the
historical `github-actions[bot]` identity skips repeated automatic reviews.

Thermos runs correctness and quality auditors, then returns one summary with actionable
findings and file/line references. The action publishes that response as a PR comment;
there is no separate inline-comment publisher or trace-summary invocation. Review output
is available in the Actions log. Session sharing is disabled.

The original Cursor Thermos rubrics and MIT license live in
[.github/review/thermos](../../.github/review/thermos), recovered from
[PR #291](https://github.com/aladh/Spotty/pull/291). Their prompts load directly through
`{file:...}` references. The default agent is explicitly Thermos, including for action
versions that do not forward the `agent` input to the session.

## Repeat a review

A repository writer can comment `/thermos` on an open, ready, same-repository PR.
This bypasses summary deduplication and posts a new review. The comment trigger becomes
available when the workflow is on the default branch; Actions workflow dispatch is not used.

OpenCode requires the triggering actor to have `write` or `admin` permission. Automatic
runs from actors without that permission, including Renovate, are skipped; a writer can
request their review with `/thermos`. Forks, closed PRs, and drafts are skipped.

## Identity and permissions

Install the [OpenCode GitHub App](https://github.com/apps/opencode-agent) on Spotty only.
The action handles OIDC exchange, publication, and token revocation. App authentication
is selected with `use_github_token: false`; the read-only `GH_TOKEN` supplied to shell
commands is separate from the App token used by the action. No App private key or
additional repository secret is required.

The App has broader write grants: contents, issues, pull requests, workflows, repository
secrets, and organization secrets when installed on an organization. Workflow permissions
limit the Actions token, not the App token. The upstream action configures Git with App
credentials and runs in a job with OIDC access; this is not a credential-isolated review.

Comment-only behavior is prompt policy. Native file editing is denied, but shell access
remains available. The upstream action can commit and push changes if the agent alters
the checkout; the review prompt prohibits those changes. The App remains subject to
Spotty's main-branch rules and has no configured bypass. Approval settings are unchanged.

## Runtime and limits

The action is pinned to the v1.18.29 commit, but its installer selects the latest OpenCode
release. The model remains `opencode/muse-spark-1.3-contributor-free` at `xhigh`, with no
fallback. The contributor-free provider may use submitted public source for Meta training;
availability and model terms remain provider-controlled.

A full-history checkout supplies source and diff context. Reviewer configuration is
extracted from the PR's base SHA into the runner temporary directory. Pure mode and
disabled project configuration prevent discovery of candidate configuration, plugins,
and skills. The `pull_request` workflow itself is evaluated from the PR merge revision;
this no longer has the base-workflow trust boundary of `pull_request_target`.

The action fetches the current PR branch before reviewing, so a delayed run may review a
newer head than the triggering event. There is no enforced revision recheck before
publication. Cancellation or timeout can prevent a final comment or token cleanup.
Automatic retries are not configured; use `/thermos` to retry a failed review. This is
not a required check or approval gate. The job times out after 20 minutes.

All reviewers can use shell, filesystem, websearch, and webfetch tools. Web search is
enabled with `OPENCODE_ENABLE_EXA=1`; no additional search credential is configured.
