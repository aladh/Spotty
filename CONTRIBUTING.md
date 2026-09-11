# Contribution workflow

Start with [AGENTS.md](AGENTS.md) for repository rules and the
[documentation index](docs/README.md#development) for development guides.

## Pull-request execution

A request to open a PR authorizes the agent to create a branch, commit the complete in-scope change,
push it, open the PR, monitor available checks and reviews during the run, and address their
findings. It does not authorize merge, release, tag, or repository-setting changes unless the
request says so.
Declare changes to product contracts, repository rules, and historical records in the PR description.

### PR acceptance

A PR is ready when all three conditions hold for its latest changes:

1. All review findings have a documented disposition and all review threads are resolved.
2. Required approvals are satisfied according to repository settings.
3. Checks are green: every applicable check has passed, with only intentional conditional skips.

Reviewers can be adversarial and may suggest unnecessary or out-of-scope work. Evaluate findings
against the code, requirements, and PR scope; fix valid issues and push back when a suggestion is
unsupported, unnecessary, or out of scope. Explain the evidence, tradeoff, or scope boundary in the
review thread when declining a suggestion. Resolve threads only after documenting their disposition.

Manual app testing is not a PR acceptance gate, and no human review is required beyond repository
settings. Report automated coverage limits honestly; separately requested manual verification may
happen after merge. Live-account work still follows the
[safe acceptance contract](docs/product/safe-testing.md#safe-acceptance-testing).
Meeting these criteria establishes readiness, not permission to merge: merge authorization remains
separate as described above.

### UI changes

Follow the [visual fidelity contract](docs/product/scope.md#visual-fidelity-and-interaction) and
report which relevant states and layouts were inspected. Describe deliberate deviations from the
Spotify reference or established baseline. Tests do not establish visual parity, and changing a
product contract requires task authorization.
