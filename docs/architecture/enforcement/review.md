# Semantic review and proof limits

[Enforcement inventory](../enforcement.md)

## Semantic agent-review families

| IDs | Decision or judgment | Canonical owner |
| --- | --- | --- |
| `DOC-PRI-001`, `DOC-PROD-001` | Safety/correctness/native-small-surface priority; experimental, unofficial, independent, no-affiliation product envelope | Root `AGENTS.md`, README, product contract, ADR 001 and ADR 005 |
| `DOC-TASTE-001`, `DOC-UI-001`, `DOC-CACHE-001` | Native-Mac restraint, truthful edge states, stable layout, accessibility, and bounded presentation cost | Product contract and `Sources/Spotty/Views/AGENTS.md` |
| `DOC-AGENT-001`, `DOC-DOD-001` | Progressive context loading and no invented human handoff | Root `AGENTS.md` |
| `DOC-MAP-001` | Repository ownership and path-specific instruction placement | Root `AGENTS.md` |
| `DOC-IMPL-001` | Declarative composition/views, existing store split, real protocols only at boundaries, typed state | `Sources/Spotty/AGENTS.md`, `Sources/Spotty/Spotify/AGENTS.md`, and `Sources/Spotty/Views/AGENTS.md` |
| `DOC-CONC-001`, `DOC-ESCAPE-001` | Treat Swift concurrency diagnostics as correctness and avoid ownership escapes | Root and scoped Spotify guidance |
| `DOC-LOG-001` | User-facing errors are actionable and logs are privacy-safe | Scoped Spotify guidance, PRIVACY, SECURITY, sanitization checks |
| `DOC-SAFE-001` | Live playback/account mutation is explicit-current-request opt-in and bounded | Product contract |
| `DOC-VER-001`, `DOC-PR-001` | Local verification scope and pull-request authorization | Root `AGENTS.md`, [verification](../../development/verification.md), and `CONTRIBUTING.md` |
| `DOC-GEN-001`, `DOC-DEP-001` | Generated/private state stays untracked; Actions/dependencies remain pinned and deliberately reviewed | Development setup and operations guide |
| `DOC-SEC-001`–`002` | Credentials/private data never enter Git; authenticated launch uses a stable Apple-issued Team ID | PRIVACY, SECURITY, development setup, `script/AGENTS.md`, signature checks |
| `DOC-ARCH-001` | New async/callback/provider/optimistic flows define owner, lifetime, cancellation, ordering, stale behavior, failure policy, and coverage | `Sources/Spotty/Spotify/AGENTS.md` |

## Source-reading proof audit (issues 187–188)

Source and Markdown checks prove lexical boundaries, not runtime behavior. The audit in issues
187–188 removed spelling assertions; their remaining coverage and review limits are:

| Subject | Current proof and limits |
| --- | --- |
| State/projection writers | Reducer/store suites and compiler access probes. Internal mutation routing still requires review. |
| Command effects and repeat | Lifecycle/follow-up, failure, parity, event-outcome, and `RepeatTransitionChecks` suites cover acceptance, rollback, reconciliation, cancellation, and duplicate refusal. The historical `PlaybackCommandEffectSpike` adds no production proof. |
| Account epochs | `AccountEpochOwnershipChecks` covers revoke, replacement, teardown, and stale work; compiler probes reject projection writes. Exact statement order requires review. |
| Connect identity | `ConnectDeviceIdentityChecks` and Rust FFI tests cover naming. Native initialization order requires review. |
| Renderer | PCM backpressure tests cover behavior; allocation pairing, Core Media ownership transfer, and failure cleanup require memory-ownership review. |
| Credentials/signing | Persistence/failure/grant suites and `SRC-KEY-001` cover durable behavior and forbidden APIs. Production wiring and signing semantics require review. |
| Native UI | `VisualStyleContractChecks` covers Home and remote-banner behavior. Layout, controls, accessibility, Reduce Motion, keyboard dispatch, and text-field interaction require UI review. |
| Engine intake | `EnginePayloadContractChecks` constructs typed C snapshots and checks conversion, copied borrowed strings, and absent fields. Domain/store suites cover presentation; owned-string freeing requires FFI review. |
| Playlist/catalog | Mutation suites cover occurrence UIDs, stale accounts, write-versus-refresh failure, and retry. `TrackTableDisplayCacheChecks` covers cache versions; `SRC-DEP-001` and `SRC-DUP-004` cover dependency construction and unsupported drag APIs. Menus, stale warnings, and protocol ownership require review. |
| Queue mutation | Management/event-outcome suites cover occurrence identity, remote removal, generations, cancellation, and stale callbacks. Native selection and local-removal capability remain review obligations. |
| Transient feedback | Presenter/workflow suites cover replacement and lifetime. Hit testing, focus, VoiceOver, and Reduce Motion require UI review. |
| Rust lexical guards | `SRC-RUST-FFI-001` and `SRC-RUST-PLAY-001` constrain wrapper/write locations. Panic, nested-runtime, and player-event tests separately cover behavior; text location does not prove ordering. |
| ABI and fixtures | Signature/layout probes remain ABI evidence. Parser fixtures exercise retained scanners; synthetic payload and persistence reads test data, not implementation spelling. |

Rust lexical guards remain in the Rust suite invoked by `Scripts/check.sh`; do not duplicate their
scanner in shell. `Backend/spotty-playback/source-input-digest.sh` defines artifact inputs; Rust
tests outside `src/` are excluded from that digest. CI uses the same input list for its diff against
the pinned engine tag, including source and license directories to catch deletions.
