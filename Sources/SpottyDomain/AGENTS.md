# SpottyDomain agent guidance

Follow [ADR 002](../../docs/architecture/adrs/ADR-002-playback-state-and-dependencies.md) for this
portable, deterministic policy layer.

- This target is portable policy. The Linux build enforces the module boundary. Review injected
  closures and globals for environment access. Live retry timing belongs to the app adapter.
- Reducer acceptance and lifetime values are behavior, not implementation trivia. Preserve stale,
  superseded, teardown, cancellation, epoch, and revision semantics when adding events or effects.
  Settled intent outcomes are immutable;
  [ADR 003](../../docs/architecture/adrs/ADR-003-playback-command-effects.md#intent-outcomes) owns
  the state machine.
- Pure queue, device, connection, and playback projection policy belongs here, with semantic
  projections kept separate from timing per
  [ADR 002 tradeoffs](../../docs/architecture/adrs/ADR-002-playback-state-and-dependencies.md#tradeoffs).
  Individual projection semantics are owned by their product contracts, ADRs, and tests.
