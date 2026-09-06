# ADR 003: Keep PlaybackEffectRegistry; reject TCA and a generic Effect type

Status: accepted on 2026-08-27.

## Context

Reducer acceptance does not own asynchronous task lifetimes, cancellation, or follow-ups. Those
need an owner, but not necessarily another state-management framework.

## Decision

Keep `PlaybackEffectRegistry`; the store starts and owns tasks. Reducer acceptance and shared
command-follow-up policy govern results. Reuse that policy at new command sites rather than adding
another runner. Keep callback identity separate from command-effect ownership.

Do not adopt The Composable Architecture (TCA) or introduce a generic `Effect` abstraction for the
current playback architecture.

## Alternatives and tradeoffs

- The existing registry adds no dependency or isolation model and keeps the domain reducer
  framework-free. Its cost is maintaining explicit command lifecycle and reconciliation tests.
- A specialized command runner would cover only transport commands while still needing the same
  lifetime and follow-up policy.
- TCA or a generic effect system would add an abstraction alongside the existing reducer and task
  owner. TCA's testing and cancellation facilities do not justify that integration for the current
  needs; its cancellation model would also need adaptation to Spotty's refusal of a second
  in-flight command of the same kind.

See [behavior enforcement](../enforcement/behavior.md) for lifecycle, reconciliation, rollback,
and generation checks.

## Revisit trigger

Reconsider when replacing `PlaybackStore` or when a demonstrated testing or effect-management need
cannot be met by the existing registry and focused suites.
