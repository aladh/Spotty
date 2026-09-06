# Agent operations for Spotty

Start with [AGENTS.md](AGENTS.md) for repository rules and the
[documentation index](docs/README.md#development) for development guides.

## Pull-request execution

[OpenCode Thermos review](docs/development/opencode-review.md) provides one advisory correctness
and quality review when a same-repository PR first becomes ready.

A request to open a PR authorizes the agent to create a branch, commit the complete in-scope change,
push it, open the PR, monitor available checks/reviews during the run, and address automated
findings. It does not authorize merge, release, tag, repository-setting changes, or issue closure
unless the request says so.

### PR acceptance

A PR is ready when all three conditions hold for its latest changes:

1. All review findings have a documented disposition and all review threads are resolved.
2. Required approvals are satisfied according to repository settings.
3. Checks are green: every applicable check has passed, with only intentional conditional skips.

Evaluate review feedback using engineering judgment. Addressing feedback does not require agreeing
with or implementing every suggestion. Fix valid issues; when declining a suggestion, explain the
reasoning, tradeoff, or scope boundary in the thread. Resolve threads only after documenting their
disposition.

After pushing fixes, wait for checks and required reviews to cover the updated head. A stale
blocking review state must be cleared through the reviewer’s normal workflow; do not bypass
repository protections.

Manual app testing is not a PR acceptance gate, and no human review is required beyond repository
settings. Report automated coverage limits honestly; separately requested manual verification may
happen after merge. Live-account work still follows the
[safe acceptance contract](docs/product/safe-testing.md#safe-acceptance-testing).
Meeting these criteria establishes readiness, not permission to merge: merge authorization remains
separate as described above.
