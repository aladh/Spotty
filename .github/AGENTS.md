# GitHub automation agent guidance

Follow [PR acceptance](../CONTRIBUTING.md#pr-acceptance) and the
[enforcement inventory](../docs/architecture/enforcement.md) for workflows and PR metadata.

- Keep a readable version comment beside action pins.
- Use least permissions and never expose credentials to untrusted pull-request code or logs.
- Preserve the [required CI aggregate](../docs/architecture/enforcement/build-and-abi.md#ci-and-release-workflow),
  the fail-closed change classification in [`ci_rust_policy.py`](../Scripts/ci_rust_policy.py), and
  separation of published app pins from engine production.
- Preserve content-keyed Rust archive reuse and configuration-safe SwiftPM cache isolation. Treat
  cache contents, restore prefixes, and timestamp refreshes as correctness-sensitive build behavior.
- Inspect workflow diffs for permissions, pins, trigger trust boundaries, shell interpolation, cache
  poisoning, and accidental coverage reduction.
