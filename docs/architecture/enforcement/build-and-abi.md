# Build, ABI, and CI enforcement

[Enforcement inventory](../enforcement.md)

## Toolchain, platform, and package graph

| IDs | Invariant | Canonical decision | Primary enforcement |
| --- | --- | --- | --- |
| `FMT-SWIFT-001`–`003` | One selected-toolchain `swift-format` contract; Spotty builds fail on warnings; wrapper discovery cannot drift | [Build and verification](../../development/verification.md) | `Scripts/format-swift.sh`, its self-test, and warning flags in `Scripts/swiftpm-env.sh` / build scripts |
| `FMT-RUST-001`–`002` | Rust is rustfmt-clean and Clippy warning-clean on locked targets | [Build and verification](../../development/verification.md) | `cargo fmt --all -- --check`; `cargo clippy --locked --all-targets -- -D warnings` in `Scripts/check.sh` |
| `CMP-PLT-001` | macOS 15+ on Apple Silicon is the supported runtime envelope | [Product scope](../../product/scope.md) and [README](../../../README.md) | `Package.swift`, ARM64 XCFramework validation and app release checks; Rust source/artifact lanes also enforce the ARM64 target; support wording remains semantic |
| `CMP-DEP-001`, `CMP-FFI-001` | Target direction is `SpottyApp -> SpottyCore -> SpottyDomain`; only SpottyCore depends on the C module | Root `AGENTS.md` architecture rules and scoped Spotify boundary guidance | SwiftPM target graph plus focused import checks |
| `CMP-CHK-001`–`002` | Test targets never ship; pure tests do not depend on SpottyCore/Rust; boundary tests remain separate | ADR 002 | SwiftPM targets and `Scripts/check.sh` |
| `CMP-TCA-001` | No TCA or generic Effect framework | ADR 003 | No external Swift effect-framework dependency in `Package.swift`, plus semantic review of generic effect abstractions |
| `CMP-LIVE-001` | Shipping code uses live integrations; fakes and synthetic hooks stay in checks | [Repository architecture](../../../AGENTS.md#architecture) | Package separation, hygiene checks, deterministic fixture checks, and semantic review |
| `CMP-PKG-001` | Packaging metadata remains parseable | [Packaging and releases](../../development/releases.md) | `plutil -lint Packaging/Info.plist` in `Scripts/check.sh` |

## ABI and cross-language contracts

| IDs | Invariant | Primary enforcement |
| --- | --- | --- |
| `ABI-SYM-001`, `ABI-USE-001` | Selected artifact C declarations equal archive exports and every retained export is consumed by `PlaybackCore.swift` | Header/archive comparison and export-use checks in `Scripts/check.sh` |
| `ABI-SIG-001` | C signatures stay compile-time compatible with Rust exports | Rust-lane generated-header C compiler type-compatibility assertions from `abi-signatures.txt`, exact fixture/export coverage, Rust compile-time function assignments, and fixture-parity tests |
| `ABI-GEN-001` | All checked-in playback function declarations and snapshot layouts reproduce from Rust using the pinned development tool | `Scripts/generate-c-header.sh --check` in the full/Rust gate; C layout and signature checks remain independent |
| `ABI-SWIFT-001` | Swift retains required callbacks, typed enums, and each nullable pointer shape | Positive and expected-failing compiler probes in `Scripts/check-c-header-imports.sh`, run in the full/Swift gate without linking or executing |
| `ABI-ARC-001` | The static archive and matching headers travel together in a pinned XCFramework; app builds never invoke Rust | SwiftPM binary target, artifact validation/provenance, explicit local override, and Rust-free build checks |

## CI and release workflow

| IDs | Invariant | Primary enforcement |
| --- | --- | --- |
| `CI-WF-001`, `CI-RG-001` | CI workflow exists and acquires ripgrep only when absent | `Scripts/check.sh` workflow assertions |
| `CI-RUST-001` | Rust cache key/content stays tied to runner architecture, toolchain, and lockfile | `Scripts/check.sh` plus semantic workflow review |
| `CI-FMT-001` | CI uses the selected toolchain formatter, not Homebrew Swift formatting/lint tools | `Scripts/check.sh` |
| `CI-REL-001` | Linux source policies, Rust, and published-artifact Swift/architecture and Release lanes feed the aggregate; engine candidates are built only for engine-input or build/validation infrastructure changes and never selected by Swift CI | Workflow lane wiring is asserted from `Scripts/check.sh`; PR-base/main-push input comparison is implemented in `Scripts/playback-candidate-needed.sh` and covered by `test_playback_candidate.py`; `test_playback_promotion.py` in the Rust/full gate covers promotion origin, job results, artifact integrity, provenance, and engine-version tag syntax |
| `CI-TOOL-001` | CI lanes select their documented toolchains and Linux/macOS runners, check out without persisted credentials, and restore caches by the exact content keys | literal workflow fragments asserted from `Scripts/check.sh`; the ast-grep CLI pin is owned by `Scripts/ast-grep/version`; Xcode/Swift pins follow the development setup guide |

Action SHA pins, least permissions, cache contents beyond asserted fragments, tag/version agreement,
release-note warnings, notarization credentials, and publication authorization remain semantic agent
review under `DOC-CI-001` and `DOC-REL-001`.
