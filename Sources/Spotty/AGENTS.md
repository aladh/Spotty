# SpottyCore agent guidance

This scope owns the `SpottyCore` composition shell and top-level services. Deeper `AGENTS.md` files
own Spotify boundaries and view rules. Read
[ADR 002](../../docs/architecture/adrs/ADR-002-playback-state-and-dependencies.md) and
[ADR 003](../../docs/architecture/adrs/ADR-003-playback-command-effects.md) before changing composition, task
ownership, or transient feedback.

## Ownership

- Keep `Sources/SpottyApp/` a thin launcher. Assemble the live object graph in the app scene and
  explicit environment factories, never inside a view or feature.
- `PlaybackEffectRegistry` owns store-level task lifetimes. Use explicit keys, cancellation, and
  replacement semantics instead of untracked work.
- `TransientFeedbackPresenter` owns transient mutation banners. It is not playback state or a
  generic event bus.
- Keep top-level composition declarative. Route Spotify/auth/playback detail through
  `Sources/Spotty/Spotify/`, pure policy through `SpottyDomain`, and recurring view behavior through
  `Sources/Spotty/Views/`.
- Add a protocol only at a real system or substitution boundary. Do not rebuild the app around a
  god controller, TCA, or a generic `Effect` type.
