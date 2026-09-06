# Playback engine contracts

[Engine ownership](playback-engine-ownership.md) · [Enforcement inventory](enforcement.md)

## Retained-engine guarantees

- Spirc load and activation failures use typed outcomes. A closed command channel or failed
  rehydration returns the reinitialization outcome; the lifecycle owner rebuilds through the
  existing recovery path. A failed activation rolls back its staged generation before readiness is
  published.
- Session, mixer, player, Spirc, and listener tasks stay local until initialization succeeds. The
  generation commits all object slots and task handles together, and failed or superseded builds
  abort and join staged work. Teardown owns the stop, cancellation, join, and generation
  invalidation sequence. Spirc gets a bounded opportunity to finish gracefully; forced shutdown
  explicitly closes its Dealer connection before replacement.
- Definitive streaming-credential rejection uses the public error kind and the two exact AP
  rejection categories at the pinned revision. Librespot keeps the detailed AP error type private,
  so this narrow adapter comparison must be audited on dependency updates; general permission
  failures never qualify. A definitive rejection clears only the engine's streaming credential cache
  for the current generation, stops retrying that credential, and crosses as a typed
  `credentials_rejected` snapshot and a distinct initialization result. Swift stops launch restore
  on that result, preserves the independent Keymaster grant, and persists the reauthorization
  requirement with it. A fresh durably adopted grant clears the requirement; refresh-revoked grants
  are cleared only for their owning account generation.
- Playback and connection snapshots carry the protocol active-device fact with the observation.
  Swift derives ownership from that fact instead of depending on connection and playback callback
  arrival order.
- The retained snapshot ABI is represented in the checked-in C header and Rust `repr(C)` types, with
  symbol/signature fixtures and a C-consumer layout probe. Boundary strings normalize missing and interior-NUL values before Swift consumes a callback.
  Empty strings also normalize to null except for playback context, where empty means clear.

## FFI surface

Control observations for connection, playback, devices, and queue are typed C snapshots with
`revision` and `session_generation`:

- `SpottyConnectionSnapshot`: `session_connected`, `spirc_ready`, `is_active_device`,
  `resume_pending`, `credentials_rejected`, `device_id`, `last_error`.
- `SpottyPlaybackSnapshot`: protocol playing/paused flags, track URI, authoritative context URI, timing,
  shuffle/repeat options, the active-device fact needed for coherent transport projection, and a
  one-observation `track_unavailable` flag for a failed current local load. Ordinary snapshots
  clear the flag; Rust filters request identity and preload failures, while Swift owns the
  actionable notice and its accepted-lifetime/optimistic-target presentation policy.
- Playback `context_uri`: null omits an update; empty explicitly clears it. Local timing events
  always omit context. Sticky context is available only through the resume getter.
- `SpottyDevicesSnapshot`: protocol members (`id`, `name`, type name) plus `active_device_id`.
- `SpottyQueueSnapshot`: unfiltered protocol rows, slim current-track identity, `queue_revision`,
  and replacement-disallow flags.

Swift projects these protocol snapshots into presentation. New fields must remain typed protocol
payloads, not Spotty presentation copy.

`spotty_playback_get_queue_snapshot` returns the last cluster queue (freed with
`spotty_playback_free_queue_snapshot`) so Swift can recover after a provisional empty `SetQueue`.
Null means no cluster snapshot has arrived, not an empty queue. This adapter cache is not another
app-facing store. Sticky resume-load identity stays in Rust behind `ResumeLoadPlan`'s narrow getters.

## Standing constraints

- Keep PCM production, Spirc, session connect, dealer cluster fetch, streaming, decryption, and decoding in
  Rust/librespot. Follow [ADR 005](adrs/ADR-005-retain-librespot.md) for protocol/license review.
  Reversals require evidence and a replacement ADR under the
  [decision-log guidance](adrs/README.md#maintaining-the-decision-log).
- Rehydrate before announcing readiness. Bootstrapping from the Web API on readiness reopens the
  stale-position window the `resume_pending` hold exists to close.
- Do not reintroduce `device_name`, `reconnect_attempt`, `connected_since_ms`, or
  `session_connection_id` into `ConnectionState` or its snapshot; reconnect backoff stays
  loop-local.
- Do not widen `spotty_playback_resume`; resume targets are Swift-owned loads.
- Do not forward raw cluster protobuf to Swift or create a second protocol state machine.
