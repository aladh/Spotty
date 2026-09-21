# Playback and queue evidence

[Product index](README.md) · [Playback contract](playback.md) · [Queue contract](queue.md)

Which checks support the intended user outcome, and what do they leave unproved? These are the
closest existing proofs, not a claim of complete coverage. The product index owns the contracts.

| Accepted outcome | Closest proof | Limit or gap |
| --- | --- | --- |
| Play/Pause stays consistent when independent engine consumers receive an old event late. Old loads cannot alter position; deactivation still permits terminal cleanup. | [Named retained Spirc/adapter traces](../../Scripts/check-transport-traces.sh) run the actual retained handlers in both command/event orders. The historical opposite-state handlers fail these traces. | Offline synthetic identities, no Spotify network or audio. This is ordering proof, not a latency or audibility measurement. |
| Resume keeps the displayed track, context, position, queue and modes until local and protocol evidence agree. | [Engine observed-resume checks](../../Backend/spotty-playback/src/observed_resume.rs) and [hydrated-resume boundary checks](../../Tests/SpottyBoundaryTests/HydratedResumeChecks.swift). | Live service acceptance and audible output require separately authorized, bounded [live testing](safe-testing.md#explicit-playback-test). |
| A refused resume remains disabled after notice dismissal, cancellation or failed selection; explicit selection recovers only after observed playback. | [Reducer model](../../Tests/SpottyDomainTests/PlaybackReducerModelChecks.swift), hydrated-resume checks, and the [Demo recovery trace](../../Tests/BrowsingHarness/Support/PlaybackTrace.swift). | Demo uses one synthetic authority: it verifies production control projections, not the two engine consumers. Automated state checks do not establish visual or VoiceOver parity. |
| Current activation resumes/pauses; different selection and explicit restart load the chosen target while retaining modes and supplied order. | [Catalog action matrix](../../Tests/SpottyBoundaryTests/CatalogPlaybackActionChecks.swift), [playlist routing checks](../../Tests/SpottyBoundaryTests/CatalogPlaylistShuffleChecks.swift), and [engine selection policy](../../Backend/spotty-playback/src/selection_load_policy.rs). | Remote payload/routing tests cannot prove every receiving Spotify client honors the request. |
| Transfer acknowledgement cannot claim that the destination plays the expected track and position. | [Intent outcome checks](../../Tests/SpottyDomainTests/PlaybackIntentChecks.swift) require matching playback and identified ownership in either order. | No live multi-device timing guarantee. Engine readiness measurement remains [#378](https://github.com/aladh/Spotty/issues/378). |
| Queue order survives delayed metadata and startup refreshes. | [Queue convergence checks](../../Tests/SpottyBoundaryTests/QueueRefreshConvergenceChecks.swift) and [Demo hydration measurement](../../Tests/BrowsingHarness/Support/QueueHydrationMeasurement.swift). | Synthetic hydration costs exclude live network latency. |
| Removing selected upcoming occurrences preserves duplicates and protocol metadata; incomplete, restricted or stale evidence fails closed. | [Mutation policy](../../Tests/SpottyDomainTests/QueueMutationChecks.swift), [management boundary checks](../../Tests/SpottyBoundaryTests/QueueManagementChecks.swift), and [intent occurrence-count checks](../../Tests/SpottyDomainTests/PlaybackIntentChecks.swift). | Local-owner removal remains unsupported. Real queue mutations need explicit authorization; ordinary gates do not perform them. |

Run the [normal verification gates](../development/verification.md#normal-verification) for code
changes. `./Scripts/browse-synthetic.sh Tests/BrowsingHarness/playback.json` records Demo recovery
checkpoints, generation, command outcomes and timing in its local report. Use the retained-engine
trace command alongside it; neither report substitutes for the other. Keep any live-account
diagnostics local under [privacy guidance](../../PRIVACY.md).
