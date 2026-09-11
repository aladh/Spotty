# ADR 003: Keep PlaybackEffectRegistry; reject TCA and a generic Effect type

Status: accepted on 2026-08-27.

## Context

Reducer acceptance does not own asynchronous task lifetimes, cancellation, or follow-ups. Those
need an owner, but not necessarily another state-management framework.

## Decision

Keep `PlaybackEffectRegistry`; the store starts and owns tasks. Reducer acceptance and shared
command-follow-up policy govern results. Reuse that policy at new command sites rather than adding
another runner. Keep callback identity separate from command-effect ownership.

`PlaybackEffectRegistry.run` is how a store effect is started: it registers, runs, and completes one
token, so no site can forget to complete it or complete one a newer effect already owns.
`replace`/`complete`/`cancel` remain for the few sites that need the pieces. Inside an effect,
`PlaybackStore.stillCurrent` is the only sanctioned revalidation after an `await`.

Do not adopt The Composable Architecture (TCA) or introduce a generic `Effect` abstraction for the
current playback architecture.

Queued commands carry a dispatch permit. Route/lifetime publication invalidates unclaimed permits;
the coordinator claims a permit immediately before committing to the local or remote operation.
Claim is the irreversible dispatch boundary, not evidence that playback succeeded. Timing and
metadata changes alone must not invalidate a route. Optimistic idle-local play retains its chosen
destination through admission. Already-sent requests still settle through reducer reconciliation.

Account teardown captures the exact canceled effect tasks and gives cooperative work a bounded
drain opportunity. The drain report identifies unsettled work; it does not claim cancellation
revoked a blocking C call or a request Spotify already received. Late tasks remain fenced by
their existing lifetime and registration identity.

### Intent outcomes

The reducer records admission, permit dispatch, successful transport return (`sent`), observed
confirmation, rejection, supersession, and expiration. The store drains the permit's synchronous
claim receipt before reducing observations, including observations arriving before transport returns.
Only accepted engine payloads received after dispatch can provide confirmation; optimistic state and
metadata cannot. Spotify does not echo our operation ID, so confirmation means a matching observed
state, not proof that our command caused it. Navigation matches a changed track or restarted
position on the same owner; unchanged same-track observations remain unconfirmed.

Each admitted request gets an eight-second account-scoped deadline in the existing registry.
Expiration releases pending admission and invalidates unsent permits, while sent actions remain
irrevocable. Late observations still update playback truth; terminal intent outcomes never change.
The retained history keeps the latest 128 records plus any active requests. Queue appends reserve
separate occurrence counts for overlapping identical URIs. A later reservation stays conservative
if an earlier dispatched append reports failure: the failed acknowledgement does not prove that
Spotify omitted its occurrence. One remaining occurrence cannot identify which append succeeded; removal requires the selected UIDs to be
absent from a newer complete Connect snapshot. Missing or ambiguous evidence expires without retry.

Rapid transport, seek, options, and transfer calls are refused while the same kind is in flight.
There is no automatic coalescing or retry. Queue adds preserve order through coordinator dispatch;
one replacement is allowed in flight. A sent append’s observation deadline does not cancel the rest
of its batch. An execution deadline stops the stalled batch and reports its unsent remainder.
Transport-return callbacks retain their acceptance meaning;
queue and transfer feedback explicitly says the request was sent. Known play targets enter local
listening history only after an observed match. Admission time, dispatch time, and
observed settlement time remain distinct in the reducer record.

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
