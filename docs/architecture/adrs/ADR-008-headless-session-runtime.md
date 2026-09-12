# ADR 008: Headless session runtime with an in-process desktop client

Status: accepted on 2026-09-12. Supersedes the `PlaybackStore` ownership and MainActor isolation
choices in [ADR 002](ADR-002-playback-state-and-dependencies.md) and
[ADR 003](ADR-003-playback-command-effects.md); their reducer and command-settlement rules remain.

## Context

Account admission, playback commands, queue authority, recovery, and teardown need one owner that
can run without a window or observable UI. Keeping them in a MainActor presentation object ties
session execution to UI scheduling and makes independent lifetime scenarios harder to express.
The existing domain reducer, effect registry, command permits, and retained engine already encode
useful safety decisions; changing their owner does not justify replacing those decisions.

A bundled XPC service can additionally contain process failures, but requires a reliable signing,
peer-identity, packaging, and audio lifecycle contract. Ad-hoc distribution does not establish that
contract. A development certificate alone does not establish Developer ID distribution or
notarization across updates.

## Decision

`SpottySessionRuntime` owns account lifecycle, the writable playback reducer state, queue precedence,
command execution, recovery, and the single teardown controller. Its session actor uses a dedicated
serial transition executor. A synchronous transition commits bounded in-memory state; network,
database, and blocking engine operations run through their separate workers. Every continuation
still validates its captured lifetime. Actor isolation cannot make a result from an older account,
engine, route, or command current.

`PlaybackStore` in `SpottyCore` becomes the MainActor presentation adapter. It applies equatable
runtime publications, owns UI observation and browsing presentation, and forwards user actions.
The local adapter has a bounded synchronous admission entrance; it must not wait for network,
storage, MainActor, or blocking FFI work inside that entrance. View code continues to read published
projections rather than the reducer snapshot. The runtime must not construct SwiftUI or AppKit
presentation objects.

`SpottyRuntimeContracts` holds typed, Sendable catalog and session values. `SpottyGateway` contains
Spotify authorization, private wire models, HTTP transports, response mapping, and operation-specific
failure interpretation. Feature stores consume domain snapshots rather than Pathfinder responses.
Catalog and metadata attempts share bounded admission, with interactive requests ahead of queued
enrichment; playback command dispatch has its own lane. Read retries and uncertain writes remain
distinct. Moving a private interface behind a target does
not make that interface stable or officially supported.

The production desktop uses this runtime in process. Closing a window keeps the app and runtime
alive; quitting terminates them. This does not provide playback after app termination or crash.
The engine adapter remains the only consumer of the playback binary, and PCM stays between that
adapter and its AVFoundation renderer.

The versioned session command/snapshot contract also has an independently exercised XPC transport
candidate. It validates peer identity, session identity, revisions, and bounded messages. Connection
loss around a dispatched write produces an unknown outcome; reconnect begins with a complete
snapshot and must not replay uncertain mutations. This transport is not a production helper, a
separately installed agent, or a second session authority.

## Tradeoffs and alternatives

The in-process choice separates authority and scheduling without claiming process containment.
A stalled transition can still delay local synchronous admission, so bounded transition work remains
a correctness requirement, not merely an optimization. The runtime retains explicit task ownership
through `PlaybackEffectRegistry`; no TCA or general-purpose effect framework is introduced.

A full XPC cutover would remove the direct local entrance but add serialization, helper startup,
crash recovery, packaging, and trust obligations. Adopt it only after packaged continuous audio,
sleep/wake, output changes, helper failure, and reconnect scenarios pass with the intended release
identity. Desktop, helper, and contract must then ship as one compatible release.

OAuth persistence remains governed by [ADR 007](ADR-007-session-persistence.md). A future move to
service-owned Keychain storage requires separately verified signing continuity and a recoverable
migration; this boundary change neither imports nor modifies old Keychain grants.
