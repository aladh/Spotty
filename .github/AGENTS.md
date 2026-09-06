# GitHub automation agent guidance

GitHub workflows and pull-request metadata are part of the verification and release boundary. Read
[agent operations](../CONTRIBUTING.md) and the
[enforcement inventory](../docs/architecture/enforcement.md) before changing them.

- Pin every GitHub Action to a full commit SHA and keep a readable version comment.
- Use least permissions and never expose credentials to untrusted pull-request code or logs.
- The required `Debug quality gate` must aggregate Rust verification, Swift/architecture
  verification, and the release compile. Parallelism and caches may reduce latency, never coverage.
- Preserve content-keyed Rust archive reuse and configuration-safe SwiftPM cache isolation. Treat
  cache contents, restore prefixes, and timestamp refreshes as correctness-sensitive build behavior.
- Do not install a second Swift formatter/linter in CI; use the selected Xcode toolchain and the
  repository wrappers. Prefer an existing runner `rg`, with the documented fallback only.
- Inspect workflow diffs for permissions, pins, trigger trust boundaries, shell interpolation, cache
  poisoning, and accidental coverage reduction.
