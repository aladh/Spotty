# GitHub automation agent guidance

GitHub workflows and pull-request metadata are part of the verification and release boundary. Read
[agent operations](../CONTRIBUTING.md) and the
[enforcement inventory](../docs/architecture/enforcement.md) before changing them.

- Pin every GitHub Action to a full commit SHA and keep a readable version comment.
- Use least permissions and never expose credentials to untrusted pull-request code or logs.
- The required `Debug quality gate` must aggregate Linux source policies, Rust verification,
  Swift/architecture verification, and the release compile. Parallelism and caches may reduce
  latency, never coverage.
- Preserve content-keyed Rust archive reuse and configuration-safe SwiftPM cache isolation. Treat
  cache contents, restore prefixes, and timestamp refreshes as correctness-sensitive build behavior.
- Use the selected Xcode toolchain for Swift formatting. The pinned ast-grep rules own migrated
  source policies on Linux; do not duplicate them with another linter or regex checks. Prefer an
  existing runner `rg` for remaining checks, with the documented fallback only.
- Inspect workflow diffs for permissions, pins, trigger trust boundaries, shell interpolation, cache
  poisoning, and accidental coverage reduction.
