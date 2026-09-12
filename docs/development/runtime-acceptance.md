# Runtime architecture acceptance

[Verification](verification.md) · [Architecture decisions](../architecture/adrs/README.md)

This guide defines the evidence needed to assess the headless runtime, retained catalog, and native
presentation work against the [architecture proposal](https://github.com/aladh/Spotty/issues/424).
A green PR establishes the repository's [PR acceptance](../../CONTRIBUTING.md#pr-acceptance);
it must not be described as proof of every proposed architecture or performance goal.

## Implemented boundary

The production desktop consumes an in-process session runtime on a dedicated transition executor.
It retains the domain reducer, command effects, account teardown, queue authority, and pinned
Rust/librespot engine. Private Spotify transport and response mapping live behind typed gateway
ports. The MainActor adapter owns UI observation and browsing presentation; a local synchronous
admission entrance forwards bounded work to the session executor.

The account-verified SQLite fallback persists complete playlist and album browsing results.
In-memory route snapshots restore playlist, album, and artist revisits. Saved rows expose freshness
and cannot authorize destructive playlist edits. Playlist and album stores subscribe to database
entity changes across active and retained routes. They apply complete, account-fenced revisions
to affected track metadata while preserving occurrence identity, membership, and collection
authority. Search, Home, library, and artist persistence are not supplied by this fallback.
New windows still start on Home; this is not persistent navigation restoration or offline startup.

Dense track, sidebar, and queue/history scrolling and selection are directly owned in AppKit;
SwiftUI still provides composition and leaf content. The Spotify appearance requirements remain
unchanged. A native implementation alone provides no measured speed improvement.

## Evidence for the implemented scope

- Run the complete gate on the final changes, including the existing reducer and boundary corpus
  and the separate runtime, gateway, and storage targets. Tests must retain independent
  expected behavior after ownership moves rather than merely exercising renamed production code.
- Exercise account replacement, request cancellation, late publication, snapshot/receipt identity,
  retirement during I/O, cache corruption/unsupported schema, purge failure, and complete-versus-
  partial collection replacement with isolated data. A stored owner or occurrence ID must never
  bypass a fresh mutation check.
- Verify shared artwork source fetches across size and tint requests, bounded retained bytes,
  oversized-image rejection, and retirement during fetch/decode. Record request and memory evidence
  separately from rendering-speed claims; no artwork disk cache is introduced.
- Revisit A → B → A with playlist search, sort, occurrence selection, and scroll state; verify stale
  content during read failure and rejection of old route/account completions. Successful writes
  and uncertain or cancelled outcomes after mutation admission must invalidate a closed route as
  well as the current page. Resource links must navigate without starting playback.
- Enrich a shared track on album B and verify its updated metadata in active and retained playlist A
  without another playlist read. Preserve duplicate occurrence IDs, server UIDs, order, date added,
  selection, freshness, and ownership; unchanged collections must retain their versions. Exercise
  query limits, missing entities, multi-page revisions, coalesced changes before acknowledgement,
  and account retirement during page reads. A partial or superseded publication must not update
  rows or turn saved content into fresh mutation authority.
- Inspect the same synthetic playlist, sidebar, queue, and history surfaces in resting, hover,
  selected, focused, disabled, inactive, narrow, and resized states. Check keyboard actions,
  accessibility order/labels, and Reduce Motion. Record the Spotify reference or established
  baseline, deliberate differences, and every unperformed state. Automated behavior tests do not
  establish visual parity.
- Measure a representative optimized build with recorded source and engine identities, scenario,
  window size, display refresh/scale, system, and workload. Separate rendered-frame and input-to-
  pixel evidence from main-run-loop callback gaps, CPU, and memory. The existing
  [historical baseline](../architecture/performance-baseline.md) cannot serve as this measurement.
  The harness's `--optimized` mode provides a testable, instrumented Release candidate with
  synthetic dependencies; it does not establish production audio behavior or a matched comparison
  against an older Debug build.

Use synthetic fixtures and the [safe testing contract](../product/safe-testing.md); architecture
acceptance does not expand live-account permissions. Attach evidence to the reviewed revision and
report missing measurements explicitly instead of inferring them from compilation or fewer updates.

## Production process

The session runtime is an in-process component of the app. Spotty does not ship or maintain a custom
session XPC transport or helper, and a process-isolation cutover is not an active acceptance or
distribution gate. Session identity, bounded snapshots, revision-gap detection, command receipts,
and truthful unknown outcomes remain runtime correctness rules even without serialization across a
process boundary. [ADR 008](../architecture/adrs/ADR-008-headless-session-runtime.md) owns this choice.

OAuth storage remains the private file from [ADR 007](../architecture/adrs/ADR-007-session-persistence.md).
A future Keychain migration must prove access across updates, developer builds, lock/unlock, and
reinstallation, and define a recoverable migration of the active grant. Old Keychain entries remain
untouched. Neither the runtime boundary nor catalog persistence establishes this migration.

## Product expansions outside this cutover

Occurrence-safe local queue removal still depends on the retained engine's operation and protocol
evidence; a native row control cannot supply it. Multi-selection drag mutations and broader
preferences or playlist administration remain governed by the existing product contracts.
Any proposal to add them needs its own supported behavior and verification rather than being
implied by the architecture.
