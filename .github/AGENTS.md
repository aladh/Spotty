# GitHub automation agent guidance

Follow [PR acceptance](../CONTRIBUTING.md#pr-acceptance) and the
[enforcement inventory](../docs/architecture/enforcement.md) for workflows and PR metadata.

- Pin every GitHub Action to a full commit SHA and keep a readable version comment.
- Use least permissions and never expose credentials to untrusted pull-request code or logs.
- Preserve the [required CI aggregate](../docs/architecture/enforcement/build-and-abi.md#ci-and-release-workflow),
  the fail-closed change classification in [`ci_rust_policy.py`](../Scripts/ci_rust_policy.py), and
  separation of published app pins from engine production.
- Preserve content-keyed Rust archive reuse and configuration-safe SwiftPM cache isolation. Treat
  cache contents, restore prefixes, and timestamp refreshes as correctness-sensitive build behavior.
- Use the selected Xcode toolchain for Swift formatting. The pinned ast-grep rules own migrated
  source policies on Linux; do not duplicate them with another linter or regex checks. Prefer an
  existing runner `rg` for remaining checks.
- Inspect workflow diffs for permissions, pins, trigger trust boundaries, shell interpolation, cache
  poisoning, and accidental coverage reduction.
