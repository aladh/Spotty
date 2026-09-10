# SpottyDomain agent guidance

Follow [ADR 002](../../docs/architecture/adrs/ADR-002-playback-state-and-dependencies.md) for this
portable, deterministic policy layer.

- This target has no UI, audio, network, storage, or FFI dependency. Do not import AppKit, SwiftUI,
  AVFoundation, or `SpottyPlaybackCore`, and do not smuggle environment access through closures or
  globals.
- Reducer acceptance and lifetime values are behavior, not implementation trivia. Preserve stale,
  superseded, teardown, cancellation, epoch, and revision semantics when adding events or effects.
  Settled intent outcomes are immutable;
  [ADR 003](../../docs/architecture/adrs/ADR-003-playback-command-effects.md#intent-outcomes) owns
  the state machine.
- Pure queue, device, connection, and playback projection policy belongs here, with semantic
  projections kept separate from timing per
  [ADR 002 tradeoffs](../../docs/architecture/adrs/ADR-002-playback-state-and-dependencies.md#tradeoffs).
  Individual projection semantics are owned by their product contracts, ADRs, and tests.
