# Contribution workflow

Start with [AGENTS.md](AGENTS.md) for repository rules and the
[documentation index](docs/README.md#development) for development guides.

## Verification commands

Run from the repository root. `python3 Scripts/verify.py --help` explains the focused command surface;
it delegates to SwiftPM and existing gates. See [verification](docs/development/verification.md)
for prerequisites, diagnostics, and choosing a normal or clean rebuild.

| Command | Purpose |
| --- | --- |
| `python3 Scripts/verify.py preflight` | Read-only tool discovery; gates validate versions and dependencies |
| `python3 Scripts/verify.py list` | Discover Swift Testing tests, including the synthetic harness |
| `python3 Scripts/verify.py test --filter ProtobufTests/testProtobuf` | Run focused tests with the existing timeout watchdog and native result artifacts |
| `python3 Scripts/verify.py swift` | Swift gate against the selected engine artifact, including synthetic helper checks |
| `python3 Scripts/verify.py rust` | Python playback checks and compiled Rust/header checks |
| `python3 -B Scripts/script_tests.py harness` | Synthetic browsing, measurement, and trace helper checks |
| `./Scripts/check-source-policy.sh` | Source, topology, documentation, and script policy checks |
| `./Scripts/check.sh` | Complete normal verification gate |
| `./Scripts/check-clean.sh` | Clean engine rebuild and complete Debug/Release verification |

Focused filters optimize local iteration and do not replace the complete gate. The wrapper's
`source`, `check`, and `clean` commands delegate to the same scripts above. `list` and `test` forward
remaining arguments to SwiftPM; the watchdog collects native Swift Testing event streams when supported.

## Pull-request execution

A request to open a PR authorizes the agent to create a branch, commit the complete in-scope change,
push it, open the PR, monitor available checks and reviews during the run, and address their
findings. It does not authorize merge, release, tag, or repository-setting changes unless the
request says so.
Declare changes to product contracts, repository rules, and historical records in the PR description.
For behavior changes, also name affected product contracts, representative scenario IDs run,
scenario IDs added or changed, and unverified acceptance scope with reasons. Use the
[acceptance manifest](Tests/BrowsingHarness/Scenarios/manifest.json) for stable IDs; explain when
the change falls outside its coverage. [Thermos](docs/development/thermos-review.md) compares
these declarations with the manifest and revision-matched evidence.

### Preventing recurrence

When fixing an issue, identify the underlying cause and where else the same failure can occur.
Apply the smallest effective safeguard against that class of error: prefer structural code changes
or automated checks; update canonical guidance when the gap is procedural.

Include prevention in the same PR when scope is small. If broader prevention would materially expand
scope or delay the fix, open and link a follow-up issue describing the failure class, proposed
safeguard, and acceptance criteria. If the fix or existing safeguards already prevent recurrence,
explain why no additional mechanism is needed.

### PR acceptance

A PR is ready when all three conditions hold for its latest changes:

1. All review findings have a documented disposition and all review threads are resolved.
2. Required approvals are satisfied according to repository settings.
3. Checks are green: every applicable check has passed, with only intentional conditional skips.

Verify the proposed merge against current main: concurrent PRs can pass separately but fail shared
constraints together. Rerun affected checks on the combined changes before merging.

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
