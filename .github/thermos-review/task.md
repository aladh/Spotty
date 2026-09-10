# Thermos GitHub review task

You are running in GitHub Actions on a checked-out pull request head. Run the Thermos workflow
(both auditors, then synthesis) over this PR and write your results as files. You have no write
access to GitHub. A trusted publication step turns your files into one review with inline
comments, thread replies, and thread resolutions.

## Inputs

The run facts at the end of this message give the repository, PR number, base and head commits,
the review mode, and file paths:

- `pr.diff`: the full PR diff (base...head).
- `changes.diff`: the range under audit. In full mode this equals `pr.diff`. In incremental mode
  it holds the changes since the previous Thermos review, limited to files the PR touches.
- `threads.json`: unresolved review threads opened by earlier Thermos reviews on this PR, each
  with its path, line, and every comment, including the author's replies.
- The repository is checked out at the PR head. `git`, `rg`, and a read-only `gh` are available.

## Review scope

- Audit `changes.diff` with both auditors. Use `pr.diff` and the repository for context so that
  every finding describes how the code behaves at the head, not at an intermediate commit.
- Report only actionable findings introduced or made reachable by this PR. Omit informational
  notes, style preferences without a concrete cost, and unrelated follow-ups.
- Do not re-report a problem already tracked by a thread in `threads.json`; evaluate it under
  thread actions instead. Do not report a problem an earlier resolved thread already covered
  unless the head reintroduces it.
- Support behavioral claims with inspected evidence rather than agreement between auditors.

## Thread actions

For each thread in `threads.json`, inspect the head and decide:

- `resolve: true` when the code at the head no longer has the problem, or the author's reply
  documents a disposition that holds up against the code (evidence-based pushback, a scope
  boundary, an accepted tradeoff). Reply briefly with what you verified.
- `resolve: false` when the problem persists or the reply does not address it. Reply only when
  you have something new to add, such as why the fix is incomplete; otherwise leave the reply
  empty.

## Outputs

Write exactly these files into the output directory named in the run facts:

1. `findings.json`: a JSON array. Each item is
   `{"path": "<repository-relative path>", "line": <line number in the head version of the file, on a line the PR diff adds or changes>, "body": "<what breaks, the evidence, and the suggested fix>"}`.
   Write `[]` when there are no findings.
2. `thread-actions.json`: a JSON array with exactly one item per thread in `threads.json`:
   `{"id": "<thread id from threads.json>", "resolve": true|false, "reply": "<short reply, or an empty string>"}`.
   Write `[]` when `threads.json` is empty.
3. `summary.md`: brief Markdown without headings. State what was inspected and how, the number of
   new findings, the disposition of each earlier thread, and coverage limits: what the review
   could not exercise (for example, no macOS build or playback run). When there are no findings
   and no thread stays open, say that no actionable findings remain in the reviewed scope; that
   text becomes the approval body. Do not claim anything you did not inspect.

Publication rules, for your awareness: findings become inline review comments on the head
commit. The review is submitted as an approval only when `findings.json` is empty and no
Thermos thread remains unresolved; otherwise it is submitted as a comment. Changes are never
formally requested.
