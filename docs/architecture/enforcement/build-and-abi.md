# Build, ABI, and CI enforcement

[Enforcement inventory](../enforcement.md)

## Toolchain, platform, and package graph

| Purpose | Owner |
| --- | --- |
| Consistent formatting and warning-clean builds | [Verification](../../development/verification.md), [check.sh](../../../Scripts/check.sh) |
| Platform, dependency direction, and non-shipping test targets | [Package.swift](../../../Package.swift), [source policies](source-checks.md) |
| The portable domain builds and its tests pass on Linux, where app and playback modules do not exist | [Package.swift](../../../Package.swift) `#if os(macOS)` graph, [CI](../../../.github/workflows/ci.yml) `Linux domain` job |
| Keep the domain free of a second effect framework | [ADR 003](../adrs/ADR-003-playback-command-effects.md) |
| Production uses live integrations; fixtures remain in tests | [Dependency ownership](../adrs/ADR-002-playback-state-and-dependencies.md), [test guidance](../../../Tests/AGENTS.md) |
| Valid bundle metadata | [check.sh](../../../Scripts/check.sh), [packaging](../../development/releases.md) |

## ABI and cross-language contracts

| Purpose | Owner |
| --- | --- |
| Agreement between selected headers, exports, and Swift consumption | [check.sh](../../../Scripts/check.sh) |
| Compile-time C/Rust signature compatibility | [Signature fixture](../../../Backend/spotty-playback/abi-signatures.txt), consumed by [generate-c-header.sh](../../../Scripts/generate-c-header.sh), [test_playback_header.py](../../../Scripts/test_playback_header.py), and [tests.rs](../../../Backend/spotty-playback/src/tests.rs) |
| Reproducible generated declarations and layouts | [Header generator](../../../Scripts/generate-c-header.sh) |
| Required callbacks, enums, and nullable pointer shapes survive Swift import | [Compiler probes](../../../Scripts/check-c-header-imports.sh) |
| Immutable matched library/header artifacts; Rust-free app builds | [ADR 006](../adrs/ADR-006-prebuilt-playback-engine.md), [artifact workflow](../../development/playback-artifacts.md) |

Generated headers do not replace signature/layout probes or memory-ownership review. Published
consumers validate their selected artifact; the Rust lane validates the evolving producer ABI.

The narrow C adapter boundary is a package-graph fact, not a source convention: `SpottyEngineAdapter` is the only
target that depends on the `SpottyPlaybackCore` binary, and `PlaybackCore` is internal to it, so no
other target can name a C symbol or reach the adapter's C surface even by adding an import. Widening
that boundary requires editing [Package.swift](../../../Package.swift), which is a reviewable
dependency change rather than a one-line import. `SpottyCore` re-exports the adapter once, in
`Sources/Spotty/EngineAdapterExports.swift`.

## CI and release workflow

CI checks cover workflow presence, tool selection, cache integrity, and complete verification.
Their executable owners are [CI](../../../.github/workflows/ci.yml) and its assertions in
[check-ci-workflow.rb](../../../Scripts/check-ci-workflow.rb), invoked by
[check.sh](../../../Scripts/check.sh). The `Linux domain` job builds `SpottyDomain` and runs
`SpottyDomainTests` in a Swift container; the macOS gate requires its result alongside source
policies. [Source policies](source-checks.md) cover the syntax-only
facets of Rust-free app scripts, workflow trust, and published-engine use; artifact validation and
build execution remain here. The required aggregate includes source policies, Rust,
Swift/architecture, and Release compilation. Source policies run unconditionally in the `policy`
job; [ci_rust_policy.py](../../../Scripts/ci_rust_policy.py) sets `macos_needed=false` for
docs-only PR changes, which skips the `macos` job and with it Rust, Swift/architecture, and Release
compilation. Rust runs on main and on PRs outside the
[app-only scope](../../development/verification.md#normal-verification); detection failures cannot
authorize a skip. Swift CI uses only published engines. Candidate builds
are selected by [input comparison](../../../Scripts/playback-candidate-needed.sh); producer validation
and publication do not depend on app compatibility with unpublished candidates.

[GitHub guidance](../../../.github/AGENTS.md) owns workflow-change constraints.
[Promotion tests](../../../Scripts/test_playback_promotion.py) exercise release eligibility and
integrity. Action pins, credentials, cache trust, release warnings, and publication authorization
still require [semantic review](review.md); literal workflow checks cannot prove those properties.
