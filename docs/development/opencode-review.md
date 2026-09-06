# OpenCode Thermos review

The advisory Actions workflow reviews same-repository PRs when opened ready, or when
marked ready after draft creation. Pushes do not trigger reviews. An existing bot
comment with the review marker skips later ready events and reruns of automatic jobs.

One OpenCode run launches independent correctness and quality subagents. The parent
posts inline findings where appropriate and a marked issue-comment summary through `gh`.
Git and filesystem tools provide source and
diff context from a full-history PR checkout; `gh` also reads PR discussion.

The original Cursor Thermos correctness and quality rubrics and MIT license are in
[.github/review/thermos](../../.github/review/thermos), recovered from
[PR #291](https://github.com/aladh/Spotty/pull/291). Orchestration differs only in OpenCode
task names and foreground execution. The files load directly into agent prompts via
`{file:...}`; no skill discovery is required. The task prompt requests Thermos, inline findings where appropriate, and a brief summary.
The summary marker is retained for automatic duplicate detection.

## GitHub identity

Install the [OpenCode GitHub App](https://github.com/apps/opencode-agent) on Spotty,
selecting only this repository. The existing CLI workflow exchanges a GitHub Actions
OIDC token with `https://api.opencode.ai/exchange_github_app_token`, using audience
`opencode-github-action`, and passes the returned installation token to `gh`.
Reviews appear as `opencode-agent[bot]`; duplicate detection also accepts historical
`github-actions[bot]` summaries. An exchange failure fails the job without falling back
to the Actions identity. No App private key or additional repository secret is needed.

The App installation grants broader permissions than the previous Actions token,
with writes to contents, issues, pull requests, workflows, repository secrets, and
organization secrets (when installed on an organization). The exchange service returns
an installation token without narrowing repositories or permissions; the workflow's
`permissions` block limits only `GITHUB_TOKEN`, not the App token. Keep the installation
limited to Spotty. This migration retains comment-only review instructions and does not
change repository approval settings. Comment-only behavior is prompt policy, not a
token permission restriction.

## Repeat a trial

Draft-to-ready skips already-reviewed PRs. To deliberately repeat, select **Run
workflow** on **OpenCode Thermos review**, choose the default branch, and enter the PR
number, or run:

```bash
gh workflow run opencode-review.yml --ref main -f pr_number=287
```

Manual runs select the current base/head SHAs and bypass comment deduplication, posting
another comment. Only open, ready, same-repository PRs are eligible. Manual runs from
other branches are skipped.

## Runtime and limits

OpenCode is pinned to 1.18.29, using `opencode/muse-spark-1.3-contributor-free` at `xhigh`.
The contributor-free provider may use submitted public source for Meta training;
availability and model terms are provider-controlled. There is no model fallback.

Reviewer configuration comes from the trusted workflow revision, separately from the
PR checkout. OpenCode runs with `--pure` and project configuration disabled to prevent
automatic loading of candidate configuration, plugins, or skills. Source and history
remain available for investigation. Shell and filesystem access are unrestricted within the runner.

GitHub lookup uses the read-only Actions token. The App token is acquired after dependency
installation and checkout, exposed to the review step, and revoked in an always-run cleanup
step before trace summarization. Cleanup failure emits a warning without failing a
published review; forced runner termination can also prevent revocation. The installation
token then expires normally. Installation and both OpenCode invocations clear OIDC
request credentials from their environments. Shell access allows direct use of the App token
through `gh` or other commands with the installation permissions described above.
Publication behavior is left to Thermos and the short task prompt;
there is no MCP server, custom publication guard, or enforced revision recheck.

Review output is redirected to a temporary runner file. A separate OpenCode invocation,
with the same shell, filesystem, and web tools but no GitHub token, summarizes that trace in the Actions log, including
after review failure. It does not export sessions or upload the trace; the file disappears
with the runner. Detailed child-agent traces are not included. Summary generation does
not clear an original review failure, and job cancellation or timeout can prevent it.
This is not a required check or approval gate. Forks are
skipped. A PR changing during review may receive no comment; a push between the final
read and publication can leave a comment about an older SHA. Automatic reviews remain
once per PR. The job times out after 20 minutes; failed runs can be retried manually.
Automatic retries are not configured.

The workflow uses runner ripgrep when available and installs it with apt otherwise. All three agents can use websearch/webfetch for upstream
research and write files anywhere in the ephemeral runner VM.
Native edit/external-directory permissions are unrestricted. Web content is untrusted review data.
The workflow explicitly enables websearch with `OPENCODE_ENABLE_EXA=1`; no additional
search credential is configured.

Inline comments posted before an interruption can remain even if the overview was never posted;
a retry may duplicate those comments because automatic deduplication still uses the overview marker.
