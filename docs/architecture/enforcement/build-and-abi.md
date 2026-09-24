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
The selected header and archive must export the same symbols, and every Swift call must exist in
that artifact. Exports shared with the current producer must be consumed; retired exports may remain
in an older pin, and new producer exports require no call until their artifact is adopted.

`SpottyEngineAdapter` is the sole production consumer of `SpottyPlaybackCore`; boundary tests depend
on it for ABI checks. Its implementation is internal. The [desktop import policy](source-checks.md)
and compiler probes close SwiftPM's transitive visibility, re-export, and inferred-access gaps.
[Package.swift](../../../Package.swift) owns dependencies; [ADR 008](../adrs/ADR-008-headless-session-runtime.md)
owns runtime ports and desktop presentation boundaries.

## CI and release workflow

[CI](../../../.github/workflows/ci.yml) and [workflow assertions](../../../Scripts/check-ci-workflow.rb)
own tool selection, cache integrity, and complete verification. Three unconditional Linux jobs run
source policies, domain build/tests, and playback/harness/watchdog/formatter-wrapper tests. The
single macOS job waits for all three, then runs compiled Rust/header checks, selected engine
candidate builds, Swift checks, acceptance scenarios, and Release compilation serially. CI's
compiled scopes omit only portable checks owned by Linux; normal local scopes retain them.
Acceptance uses the Debug gate's SDK and compiler settings so SwiftPM can reuse fresh products.

The [trusted base classifier](../../../Scripts/ci_rust_policy.py) skips macOS only for documentation-only
PRs and can skip compiled Rust for app-only PRs. Main runs both toolchains. Unknown paths or
classification failures cannot authorize a skip; source and script checks remain unconditional.
Swift CI uses published engines. [Candidate selection](../../../Scripts/playback-candidate-needed.sh)
and [publication](../../development/playback-artifacts.md#publish-a-tested-candidate) validate the
producer independently of app compatibility with unpublished binaries.

The [acceptance workflow](../../../.github/workflows/acceptance-scenarios.yml) supports dispatch and
reusable calls. Both run representative and holdout corpora once with a deadline, retain failure
artifacts, and require execution, summary, and upload success. These synthetic checks do not prove
GUI, sandbox, or live-account behavior.

Ordinary non-candidate PRs target five minutes on macOS; producing an XCFramework is an explicit
exception. The Swift Debug step has a 15-minute watchdog within the candidate-capable job's
120-minute ceiling. Per-invocation test deadlines and diagnostics are in
[verification](../../development/verification.md#normal-verification).

[GitHub guidance](../../../.github/AGENTS.md) owns workflow-change constraints.
[Promotion tests](../../../Scripts/test_playback_promotion.py) exercise release eligibility and
integrity. Action pins, credentials, cache trust, release warnings, and publication authorization
still require [semantic review](review.md); literal workflow checks cannot prove those properties.
