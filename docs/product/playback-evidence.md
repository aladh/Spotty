# Playback and queue evidence

[Product index](README.md) · [Playback contract](playback.md) · [Queue contract](queue.md)

The table links the current automated checks to the behavior they exercise. See the
[historical Swift evidence guide](https://github.com/aladh/Spotty/blob/9b5d72b686ac094148b395006918cc1215cbb8e3/docs/product/playback-evidence.md) for that revision's broader app suite.

| Accepted outcome | Closest proof | Limit or gap |
| --- | --- | --- |
| Late events from old loads cannot change transport or position. Deactivation permits terminal cleanup. | [Named transport traces](../../Scripts/check-transport-traces.sh). | Synthetic event order. |
| Resume preserves the target until player and protocol evidence agree. | [Observed resume](../../Rune/src/playback/observed_resume.rs) and [selection policy](../../Rune/src/playback/selection_load_policy.rs). | Live service acceptance and audible output require [live testing](safe-testing.md#explicit-playback-test). |
| Resume retains queue and playback modes and a refused resume stays blocked until observed recovery. | [Observed resume and refusal tests](../../Rune/src/playback/observed_resume.rs) and [worker state tests](../../Rune/src/live/mod.rs). | Synthetic queue and mode convergence, plus refusal evidence. Native playback and denial from Spotify remain unverified. |
| Playback and queue mutations require appropriate observation and ownership. | [Intent settlement](../../Rune/src/live/intent.rs) and [session tests](../../Rune/src/live/mod.rs). | Covers encoded admission and synthetic outcomes. |
| A device transfer settles after the intended owner appears in authoritative state. | [Intent settlement](../../Rune/src/live/intent.rs). | Synthetic owner observations. Transfer acknowledgement and time to audible output need a native Connect run. |
| Queue duplicates and protocol metadata survive projection. | [Queue snapshots](../../Rune/src/playback/queue_snapshot_tests.rs). | Real queue mutations require explicit authorization. |
| Queue state converges while labels load and playback changes. | [Queue worker and hydration](../../Rune/src/live/mod.rs). | Concurrent Connect and metadata service timing remains unverified. |
| Track selection and queue actions follow the shown order and device ownership. | [Rune app interaction tests](../../Rune/src/main.rs). | Synthetic UI and service state. |

Run the [normal verification gates](../development/verification.md#normal-verification) for code
changes. Keep live-account diagnostics local under [privacy guidance](../../PRIVACY.md).
