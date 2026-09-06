# Build, ABI, and CI enforcement

[Enforcement inventory](../enforcement.md)

## Toolchain, platform, and package graph

| IDs | Purpose | Owner |
| --- | --- | --- |
| `FMT-SWIFT-001`–`003`, `FMT-RUST-001`–`002` | Consistent formatting and warning-clean builds | [Verification](../../development/verification.md), [check.sh](../../../Scripts/check.sh) |
| `CMP-PLT-001`, `CMP-DEP-001`, `CMP-FFI-001`, `CMP-CHK-001`–`002` | Platform, dependency direction, and non-shipping test targets | [Package.swift](../../../Package.swift), [source policies](source-checks.md) |
| `CMP-TCA-001` | Keep the domain free of a second effect framework | [ADR 003](../adrs/ADR-003-playback-command-effects.md) |
| `CMP-LIVE-001` | Production uses live integrations; fixtures remain in tests | [Architecture rules](../../../AGENTS.md#architecture), [test guidance](../../../Tests/AGENTS.md) |
| `CMP-PKG-001` | Valid bundle metadata | [check.sh](../../../Scripts/check.sh), [packaging](../../development/releases.md) |

## ABI and cross-language contracts

| IDs | Purpose | Owner |
| --- | --- | --- |
| `ABI-SYM-001`, `ABI-USE-001` | Agreement between selected headers, exports, and Swift consumption | [check.sh](../../../Scripts/check.sh) |
| `ABI-SIG-001` | Compile-time C/Rust signature compatibility | [Signature fixture](../../../Backend/spotty-playback/abi-signatures.txt), Rust tests, and producer ABI checks |
| `ABI-GEN-001` | Reproducible generated declarations and layouts | [Header generator](../../../Scripts/generate-c-header.sh) |
| `ABI-SWIFT-001` | Required callbacks, enums, and nullable pointer shapes survive Swift import | [Compiler probes](../../../Scripts/check-c-header-imports.sh) |
| `ABI-ARC-001` | Immutable matched library/header artifacts; Rust-free app builds | [ADR 006](../adrs/ADR-006-prebuilt-playback-engine.md), [artifact workflow](../../development/playback-artifacts.md) |

Generated headers do not replace signature/layout probes or memory-ownership review. Published
consumers validate their selected artifact; the Rust lane validates the evolving producer ABI.

## CI and release workflow

`CI-WF-001`, `CI-RG-001`, `CI-RUST-001`, `CI-FMT-001`, `CI-REL-001`, and `CI-TOOL-001` cover
workflow presence, tool selection, cache integrity, and complete verification. Their executable
owners are [CI](../../../.github/workflows/ci.yml) and its assertions in
[check.sh](../../../Scripts/check.sh). [Source policies](source-checks.md) cover the syntax-only
facets of `CI-TOOL-001` and `ABI-ARC-001`; artifact validation and build execution remain here. The required aggregate includes source policies, Rust,
Swift/architecture, and Release compilation. Rust runs on main and on PRs outside the
[app-only scope](../../development/verification.md#normal-verification); detection failures cannot
authorize a skip. Swift CI uses only published engines. Candidate builds
are selected by [input comparison](../../../Scripts/playback-candidate-needed.sh); producer validation
and publication do not depend on app compatibility with unpublished candidates.

[GitHub guidance](../../../.github/AGENTS.md) owns workflow-change constraints.
[Promotion tests](../../../Scripts/test_playback_promotion.py) exercise release eligibility and
integrity. Action pins, credentials, cache trust, release warnings, and publication authorization
still require [semantic review](review.md); literal workflow checks cannot prove those properties.
