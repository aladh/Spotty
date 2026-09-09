# SpottyDomain agent guidance

Follow [ADR 002](../../docs/architecture/adrs/ADR-002-playback-state-and-dependencies.md) for this
portable, deterministic policy layer.

- This target has no UI, audio, network, storage, or FFI dependency. Do not import AppKit, SwiftUI,
  AVFoundation, or `SpottyPlaybackCore`, and do not smuggle environment access through closures or
  globals.
- Reducer acceptance and lifetime values are behavior, not implementation trivia. Preserve stale,
  superseded, teardown, cancellation, epoch, and revision semantics when adding events or effects.
- Queue, device, connection-snapshot, and playback-snapshot projection policy belongs here when it
  is pure. Preserve occurrence identity, authoritative ordering/provenance, the distinction between
  protocol state and metadata labels, the session-phase/empty-device-ID semantics in
  `ConnectionSnapshotProjection`, and transport/empty-URI/timestamp semantics in
  `PlaybackSnapshotProjection`. Resume-load target order for user resume and reconnect
  rehydration lives in `ResumeLoadPlan`, captured from sticky resume-load URIs rather than
  presentation snapshots.
