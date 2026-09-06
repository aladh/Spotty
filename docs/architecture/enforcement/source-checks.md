# Source and topology enforcement

[Enforcement inventory](../enforcement.md)

## Focused source and topology checks

These rules are intentionally lexical; they complement rather than replace semantic behavior tests.
Migrated Swift policies use `Scripts/ast-grep/rules`, run by `Scripts/check-source-policy.sh` on Linux
and in the local full gate. Syntax fixtures and file-routing tests protect matching and owner scope;
compiler checks remain on macOS. The rules do not resolve Swift symbols or prove execution order.

| IDs | Exact boundary | Owner |
| --- | --- | --- |
| `SRC-DOM-001` | SpottyDomain has no AppKit, SwiftUI, AVFoundation, or C-module import | `Scripts/ast-grep/rules` |
| `SRC-FFI-001`–`002` | One C-module importer and one `PlaybackCore` caller | `Scripts/ast-grep/rules` |
| `SRC-DEP-001` | Views and named feature stores do not construct live auth/network/playback dependencies | `Scripts/ast-grep/rules`; new store paths require semantic scope review |
| `SRC-ISO-001` | Shipping Swift contains no `nonisolated(unsafe)` | `Scripts/ast-grep/rules` |
| `SRC-UI-001` | Fixed dark appearance has one owner and shipping code does not add appearance-mode branching | `Scripts/ast-grep/rules` plus [product scope](../../product/scope.md) |
| `SRC-PROJ-001` | Playback projections expose no external mutation access | Compiler positive/negative probes in `Scripts/check-playback-projection-access.sh`, after the Debug boundary build |
| `SRC-KEY-001` | `KeychainManager.swift` contains no data-protection Keychain or access-group API references | `Scripts/ast-grep/rules`, with allowed/forbidden syntax fixtures; storage and signing semantics remain behavior-tested or reviewed |
| `SRC-RUST-FFI-001` | C exports enter named panic barriers; direct `RUNTIME.block_on` stays in the runtime owner | Retained Rust source scanner plus barrier panic/nested-runtime behavior tests |
| `SRC-RUST-PLAY-001` | Production `IS_PLAYING=true` writes stay in the Playing event owner | Retained Rust source scanner plus player-event behavior tests; the scanner is not proof of execution ordering |
| `SRC-INOUT-001` | Revision gates do not use `lastRevision: inout` | `Scripts/ast-grep/rules`; epoch correctness remains behavior-tested |
| `SRC-HYG-001`–`004` | No tracked generated/private artifacts, security placeholders, mock/demo tombstones, or shipping `LogicChecks` directory | `Scripts/check.sh`, gitignore, and privacy review |
| `SRC-DUP-004` | View code does not introduce the intentionally unsupported drag APIs | `Scripts/ast-grep/rules` and [playlist behavior](../../product/playlists.md) |
| `SRC-SIGN-001` | Authenticated development launch requires the Apple anchor + Team ID validator and never silently falls back to a self-signed identity; packaging keeps the identity override and validation stays `--keychain-stable` | `Scripts/check.sh` signing-policy assertions over `script/build_and_run.sh`, `Scripts/package-app.sh`, and `Scripts/validate-app.sh`; behavior remains semantic review under `DOC-SEC-002` |

The removed IDs `SRC-OBS-001`–`003`, `SRC-WRITER-001`, `SRC-DUP-003`, `CI-OBS-001`,
`CI-SWIFT-001`, and `ABI-JSON-001` stay retired. Do not recreate them as duplicate snapshots; their behavior is owned by
the package graph, deterministic suites, current focused checks, or [semantic review](review.md).
