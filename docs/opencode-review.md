# OpenCode Thermos review

The advisory Actions workflow reviews same-repository PRs when opened ready, or when
marked ready after draft creation. Pushes do not trigger reviews. An existing bot
comment with the review marker skips later ready events and manual Actions reruns.
A failed run without a published comment can be retried from Actions.

One OpenCode run launches independent correctness and quality subagents, then
consolidates their findings into one ordinary PR comment with source links. The
original Cursor Thermos rubrics and MIT license are preserved in
[.github/review/thermos](../.github/review/thermos), recovered verbatim from
[PR #291](https://github.com/aladh/Spotty/pull/291). The prompt adapts Cursor's background
orchestration to OpenCode foreground tasks launched together; the vendored orchestration
file is reference material, not part of the live prompt. The correctness task uses MCP
for its post-audit discussion lookup. This mimics the review method, not Cursor's model
or a guarantee of equivalent findings.

The correctness and quality files are loaded directly into agent prompts using
OpenCode's `{file:...}` configuration substitution. They are not discoverable skills:
no `.agents/skills` installation or `skill` tool invocation is needed for this fixed
workflow.

The workflow uses OpenCode 1.18.29, GitHub MCP 1.12.0, and
`opencode/muse-spark-1.3-contributor-free` with `xhigh` reasoning. The contributor-free
provider may use submitted public source for Meta training; availability and model
terms are provider-controlled. No model fallback is configured.

Configuration comes from the trusted base workflow revision. Candidate files are read
through MCP at commit SHAs, never checked out or executed. Only source/PR read tools
and comment creation are exposed; subagents cannot publish. The job token has
`contents: read` and `pull-requests: write`. The latter is broader than comments and
repository-wide; MCP configuration narrows agent tools, not the token's permissions.
There is no custom MCP guard or publication validator. Revision checks, consolidation,
and the single-comment instruction rely on the agent. Actions logs hold run output.

This is not a required check or an approval gate. It starts serving new eligible PRs
once the workflow is on the default branch. Fork PRs are skipped. A PR changing while
the review runs may receive no comment; subsequent pushes do not retry it.

A push between the final model read and comment creation can still leave a review of
an older revision. Comments identify the reviewed SHA; the once-per-PR marker still
suppresses later reviews. A timeout is reported by Actions and can be rerun manually
when no comment was published. Automatic retries and fallback models are not configured.
