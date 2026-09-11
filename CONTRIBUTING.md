# Agent operations for Spotty

Start with [AGENTS.md](AGENTS.md) for repository rules and the
[documentation index](docs/README.md#development) for development guides.

## Pull-request execution

[Thermos review](docs/development/thermos-review.md) reviews each push to a ready
same-repository PR for correctness and quality, resolves its own threads once they are addressed,
and approves when no actionable findings remain. The comment-only
[documentation review](docs/development/docs-review.md) reviews PRs that touch documentation the
same way without approving, and additionally requires that any change to a product contract,
repository rule, or historical record be declared in the PR description.

A request to open a PR authorizes the agent to create a branch, commit the complete in-scope change,
push it, open the PR, monitor available checks/reviews during the run, and address automated
findings. It does not authorize merge, release, tag, or repository-setting changes unless the
request says so.

### PR acceptance

A PR is ready when all three conditions hold for its latest changes:

1. All review findings have a documented disposition and all review threads are resolved.
2. Required approvals are satisfied according to repository settings.
3. Checks are green: every applicable check has passed, with only intentional conditional skips.

Reviewers can be adversarial and may suggest unnecessary or out-of-scope work. Evaluate findings
against the code, requirements, and PR scope; fix valid issues and push back when a suggestion is
unsupported, unnecessary, or out of scope. Explain the evidence, tradeoff, or scope boundary in the
review thread when declining a suggestion. Resolve threads only after documenting their disposition.

After pushing fixes, wait for checks and required reviews to cover the updated head. A stale
blocking review state must be cleared through the reviewer’s normal workflow; do not bypass
repository protections.

Manual app testing is not a PR acceptance gate, and no human review is required beyond repository
settings. Report automated coverage limits honestly; separately requested manual verification may
happen after merge. Live-account work still follows the
[safe acceptance contract](docs/product/safe-testing.md#safe-acceptance-testing).
Meeting these criteria establishes readiness, not permission to merge: merge authorization remains
separate as described above.

### UI changes

Review visual fidelity separately from functional correctness. For an affected UI surface, the PR
must identify the Spotify reference (or established baseline when unavailable), describe the visible
before/after change, and explain any deliberate deviation under the
[visual fidelity contract](docs/product/scope.md#visual-fidelity-and-interaction).
Check resting, hover, selected, focused, disabled, and inactive states as applicable, plus narrow
layout. Interaction fixes must retain visual requirements; contract edits need task authorization,
not just an implementation that now looks different. Report which states were actually inspected
and which remain unverified. Passing behavior tests does not establish visual parity.
Use synthetic fixtures for repeatable visual evidence within the authorized acceptance scope;
this does not add a human approval or live-account testing gate.
