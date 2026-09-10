# SpottyCore agent guidance

Follow [state and dependency ownership](../../docs/architecture/adrs/ADR-002-playback-state-and-dependencies.md)
and [command effects](../../docs/architecture/adrs/ADR-003-playback-command-effects.md) for composition
and task lifetimes. Spotify and Views have narrower guidance.

- Keep top-level composition declarative. Route Spotify/auth/playback detail through
  `Sources/Spotty/Spotify/`, pure policy through `SpottyDomain`, and recurring view behavior through
  `Sources/Spotty/Views/`.
- `PlaybackEffectRegistry` owns store-level task lifetimes and settlement per ADR 003.
- Model types do not own network, auth, or playback dependencies; native system adapters dispatch
  narrow store actions.
- Add a protocol only at a real system or substitution boundary. Do not rebuild the app around a
  god controller, TCA, or a generic `Effect` type.
