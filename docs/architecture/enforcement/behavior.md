# Deterministic behavior enforcement

[Enforcement inventory](../enforcement.md) · [Rune verification](../../development/verification.md)

| Behavior | Executable checks |
| --- | --- |
| Generation admission, rollback, stale work, and transactional playback lifetimes | [Playback tests](../../../Rune/src/playback) and [transport traces](../../../Scripts/check-transport-traces.sh) |
| Resume target, freshness, connection ownership, and readiness | [Observed resume](../../../Rune/src/playback/observed_resume.rs) and [cluster application](../../../Rune/src/playback/connect_cluster_apply_tests.rs) |
| Command admission, queue evidence, and retirement | [Session worker](../../../Rune/src/live/mod.rs) and [intent settlement](../../../Rune/src/live/intent.rs) |
| Playlist mutation authority, requested row occurrences, and user feedback | [Catalog mutations](../../../Rune/src/live/catalog.rs) and [UI selection tests](../../../Rune/src/main.rs) |
| Protocol and PCM ownership | [Session lifecycle and observation fixtures](../../../Rune/src/playback) and [audio output](../../../Rune/src/live/audio.rs) |
| Credential protection and grant rotation | [Storage and authorization tests](../../../Rune/src/live/auth.rs) |
| Catalog decoding and UI interaction | [Catalog tests](../../../Rune/src/live/catalog.rs) and [Rune app tests](../../../Rune/src/main.rs) |

The [named acceptance scenarios](../../../Rune/acceptance.json) run the Cargo suite and capture the synthetic reference with fixture data. The trace gate checks that each named transport test is discoverable. Use the [product contracts](../../product/README.md) for intended behavior and [safe testing](../../product/safe-testing.md) for actions on a real account.

The archived Swift evidence includes the randomized [playback reducer model checks](../../../Tests/SpottyDomainTests/PlaybackReducerModelChecks.swift). The [historical enforcement guide](https://github.com/aladh/Spotty/blob/9b5d72b686ac094148b395006918cc1215cbb8e3/docs/architecture/enforcement/behavior.md) describes the full suite for that revision.
