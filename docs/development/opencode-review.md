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

## Repeat a trial

Draft-to-ready skips already-reviewed PRs. To deliberately repeat, select **Run
workflow** on **OpenCode Thermos review**, choose the default branch, and enter the PR
number, or run:

```bash
gh workflow run opencode-review.yml --ref main -f pr_number=287
```

Manual runs select the current base/head SHAs and bypass comment deduplication, posting
another comment. Only open, ready, same-repository PRs are eligible. Manual runs from
other branches are skipped. The trigger becomes available after this change reaches
the default branch.

## Runtime and limits

OpenCode is pinned to 1.18.29, using `opencode/muse-spark-1.3-contributor-free` at `xhigh`.
The contributor-free provider may use submitted public source for Meta training;
availability and model terms are provider-controlled. There is no model fallback.

Reviewer configuration comes from the trusted workflow revision, separately from the
PR checkout. OpenCode runs with `--pure` and project configuration disabled to prevent
automatic loading of candidate configuration, plugins, or skills. Source and history
remain available for investigation. Shell and filesystem access are unrestricted within the runner.

The token is exposed only during GitHub lookup and review, not dependency installation.
It grants `contents: read` and `pull-requests: write`, with repository-wide PR permissions
broader than comments. Shell access allows direct use of that token through `gh` or
other commands. Publication behavior is left to Thermos and the short task prompt;
there is no MCP server, custom publication guard, or enforced revision recheck.

Actions logs hold run output. This is not a required check or approval gate. Forks are
skipped. A PR changing during review may receive no comment; a push between the final
read and publication can leave a comment about an older SHA. Automatic reviews remain
once per PR. The job times out after 20 minutes; failed runs can be retried manually.
Automatic retries are not configured.

The workflow uses runner ripgrep when available and installs it with apt otherwise. All three agents can use websearch/webfetch for upstream
research and write files anywhere in the ephemeral runner VM.
Native edit/external-directory permissions are unrestricted. Web content is untrusted review data.
The workflow explicitly enables websearch with `OPENCODE_ENABLE_EXA=1`; no additional
search credential is configured.

The task asks for inline diff comments where appropriate and a brief summary.
Publication uses `gh`. Inline comments posted before an
interruption can remain even if the overview was never posted; a retry may duplicate
those comments because automatic deduplication still uses the overview marker.
