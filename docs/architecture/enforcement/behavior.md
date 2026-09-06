# Deterministic behavior enforcement

[Enforcement inventory](../enforcement.md)

## Deterministic behavior

| IDs | Invariant | Canonical decision | Primary enforcement |
| --- | --- | --- | --- |
| `TST-STATE-001` | `PlaybackState` is one atomic snapshot and `PlaybackReducer` is its mutation entrance | ADR 002 | Domain reducer/lifecycle/presentation tests, real-store boundary tests, and compiler mutation-access probes |
| `TST-CMD-001` | Store/coordinator/registry ownership, acceptance gating, same-lifetime reconciliation, and inert stale outcomes | ADR 003 | Command lifecycle, presentation, failure, parity, registry, and event-outcome suites |
| `TST-EPC-001`, `TST-ENV-001` | Generations, revisions, cancellation, stale-result protection, ordered callback delivery, and lock-safe fan-out | ADR 002 | Session/epoch/fan-out Swift checks plus Rust generation/listener tests |
| `TST-LIF-001` | Rust lifecycle writes serialize; reconnect and init revalidate generations under the owner mutex | ADR 001–002 | `lifecycle_serialization_tests.rs`, `session_lifecycle.rs` tests, and related Rust suites |
| `TST-FFI-001` | Every C export is panic-contained; nested runtime fails safely; Rust locks do not cross Swift callbacks | ADR 001 and scoped agent guidance | Rust export/runtime tests plus ABI signature coverage |
| `TST-QUE-001` | Swift owns queue presentation over authoritative unfiltered protocol state; the engine sends a typed C queue snapshot (protocol rows, slim current-track identity, `queue_revision`, replacement-disallow flags) | ADR 002 and ADR 005 | Domain suite for presentation; Rust C-snapshot layout/callback/getter coverage for the wire |
| `TST-DEV-001` | `ConnectDeviceProjection` owns device activity, sort, and empty-type fallback; the engine sends a typed C device-list snapshot (protocol members plus `active_device_id`) | ADR 005 | Domain suite for presentation; Rust C-snapshot layout/callback coverage for the wire |
| `TST-CON-001` | `ConnectionSnapshotProjection` owns session phase and empty-device-ID fallback; the engine sends a typed C connection snapshot (session flags, `credentials_rejected`, `device_id`, `last_error`) | ADR 005 | Domain suite for presentation; Rust C-snapshot layout/callback coverage for the wire |
| `TST-PBK-001` | `PlaybackSnapshotProjection` owns engine playback transport, empty-URI identity, and timestamp correction; unused protocol context is omitted from the playback ABI, and C scalar repeat flags are decoded to Swift booleans before projection | ADR 005 | `EnginePayloadContractChecks.swift` for C-to-Swift flag decoding; Domain suite for projection; Rust C-snapshot layout/callback coverage for the wire |
| `TST-RES-001` | One Swift `ResumeLoadPlan` supplies sticky resume-load targets for user resume and reconnect rehydration. The engine holds readiness behind `resume_pending`; Swift issues at most one load sequence per engine session generation. | ADR 005 | `ResumeLoadPlanChecks.swift`, `ResumeLoadSequenceChecks.swift`, workflow stale-window coverage, and Rust identity/window/export-signature coverage |
| `TST-PCM-001` | PCM bypasses observable UI state and callbacks stay bounded | ADR 001–002 | PCM write-space/backpressure boundary checks plus semantic timing review |
| `TST-PLM-001`, `TST-FBK-001` | Playlist writes stay behind mutation owners; transient mutation feedback stays out of playback state | ADR 002 and product contract | Playlist/editability and transient-feedback suites |
| `TST-DEP-001` | Live dependencies are assembled at composition; views/stores use narrow injected boundaries | ADR 002 | Package/source topology plus injected workflow checks |
| `TST-FIX-001` | Fixtures are reduced, synthetic, and non-identifying | Product/privacy contract | Fixture contract suite plus semantic privacy review |
| `TST-RUST-001` | Locked Rust suite owns Connect recovery, protocol serialization, generations, export signatures, and the reconnect rehydration window; resume target order is Swift-owned under `TST-RES-001` | ADR 001 and ADR 005 | `cargo test --locked` in `Scripts/check.sh` |
| `TST-GATE-001` | The complete gate runs every discovered Swift test in both targets; repeat count is bounded to 1–25 | Agent operations | `Scripts/check.sh` test filtering/repeat behavior |
