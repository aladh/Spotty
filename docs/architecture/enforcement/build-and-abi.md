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

The portable graph supports isolated macOS policy tests through `verify.py domain`; named Gateway,
CatalogStorage, and TestSupport tests use a second engine-free graph. Both reuse the full manifest's
target declarations. [Manifest probes](../../../Scripts/check-package-graphs.py) resolve these graphs
with an invalid playback override, compare shared declarations, and verify lockfile isolation.
App and complete-gate entry points explicitly restore the full graph; see
[workspace selection](../../development/verification.md#normal-verification).

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

`SpottyEngineAdapter` is the sole production consumer of `SpottyPlaybackCore`; its own test target
checks C snapshot ownership and event delivery. Its implementation is internal. The [desktop import policy](source-checks.md)
and compiler probes close SwiftPM's transitive visibility, re-export, and inferred-access gaps.
[Package.swift](../../../Package.swift) owns dependencies; [ADR 008](../adrs/ADR-008-headless-session-runtime.md)
owns runtime ports and desktop presentation boundaries.

## CI and release workflow

[CI](../../../.github/workflows/ci.yml) and [workflow assertions](../../../Scripts/check-ci-workflow.rb)
own tool selection, cache integrity, and complete verification. Three unconditional Linux jobs run
source policies, domain build/tests, and playback/harness/watchdog/formatter-wrapper tests. The
macOS work starts after source policies in four independent lanes: contracts (shipping Debug,
format, package, ABI, compiler and packaging checks), complete Swift tests plus acceptance,
distribution Release plus size reporting, and classified Rust/header verification plus candidate
production. Each Swift consumer resolves and validates its own published engine. The internal
quality aggregate requires every Linux lane and every explicitly selected macOS lane. Missing,
failed, cancelled or inconsistent outcomes fail closed; only classified skips are accepted.

`SPOTTY_CHECK_PHASE` partitions only CI's `swift-compiled` scope. Normal verification remains
complete. Compilation in independent checkouts trades additional runner work for shorter elapsed
time; the complete native suite and each semantic/compiler assertion still execute once per PR.
Main retains three native repetitions. Acceptance reuses its own lane's Debug products and settings.

Swift's contracts, tests and Release caches bind compiler, configuration, package, immutable pin
and both SDK identities: wrapper-selected (`sdk`, labelled `wrapper-selected`) and Xcode default
(`xcode_sdk`), each with version, build and SDKSettings digest. SwiftBuild can choose Xcode despite
SDKROOT; matching metadata does not identify the consumed SDK. Rust's exact engine-input key has
a compiler/SDK/profile/locked-dependency compatibility prefix so Cargo reuses unchanged dependencies
and rebuilds changed bridge sources. Both toolchains bind the scoped transfer policy; a changed
policy cannot restore older, incomplete trees. Timestamps are restored only for matching content;
missing or incompatible caches compile normally.

Successful main lanes export scoped bundles. After every quality lane succeeds, a separate publisher
validates source/scope/content, restores owned products in a fresh runner, and saves caches. Required
`macOS checks` also requires this publication on main; PR and fork code skip the publisher. Optional
phase JSONL and Cargo artifacts describe costs. Compiler/cache owners stay isolated.
The transfer permits dependency source directories named `credentials` within Cargo Git checkouts
only when their files or links exactly match tracked HEAD blobs at the checkout's revision.
Both PR and main engine lanes preflight the actual admitted Cargo Git inputs after Rust verification,
before restoring or compiling Release products. A rejected proof stops production and reports only
a fixed failure stage and process status. Export and staged restoration repeat the proof before
publication or cleanup; the preflight does not authorize later changed bytes. Unproved existing
inputs remain protected during owned replacement. Registry credential directories, credential
stores, secret filenames, bare credential files or links, and material outside the explicitly
owned roots remain excluded. Export, validation, link checks and replacement cleanup share the
scope-aware exclusion and public-source proof contract.
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

Ordinary non-candidate PRs target five minutes on macOS; the measured engine-changing target and cold/cache costs are tracked in
[#587](https://github.com/aladh/Spotty/issues/587). Each macOS verification lane has a 120-minute job ceiling.
`Run Swift contracts` in the contracts lane and `Run checks` in the Swift-tests lane each have a
15-minute step limit. Per-invocation test deadlines and diagnostics are in
[verification](../../development/verification.md#normal-verification).

[GitHub guidance](../../../.github/AGENTS.md) owns workflow-change constraints.
[Promotion tests](../../../Scripts/test_playback_promotion.py) exercise release eligibility and
integrity. Action pins, credentials, cache trust, release warnings, and publication authorization
still require [semantic review](review.md); literal workflow checks cannot prove those properties.
