# Session architecture disposition — 2026-09-30

The account-workspace experiment supports narrow ownership locality. The implemented session and
catalog boundaries remain justified; neither the experiment nor the
[isolated memory investigation](2026-09-30-catalog-memory.md) warrants a whole asynchronous cutover.
[ADR 008](../adrs/ADR-008-headless-session-runtime.md) and
[ADR 009](../adrs/ADR-009-account-catalog-retention.md) remain accepted. This record distinguishes
accepted implementation from principles and rejected expansion; final integration evidence belongs
to [#590](https://github.com/aladh/Spotty/issues/590).

| Proposal | Disposition and reason |
| --- | --- |
| Account-scoped workspace and independent lifetime owners | Retain the principle and existing composition. The headless runtime owns account/playback/queue/recovery/teardown; provider, storage, query, entity-observation and artwork lifetimes remain distinct. A universal facade offers no demonstrated deletion of caller obligations. |
| Replace synchronous admission with an asynchronous actor/client entrance | Reject as required implementation. Checked dedicated-executor admission remains bounded and does not await network, storage, MainActor or blocking FFI. The prototype did not verify real dispatch, feedback latency or cancellation equivalence. |
| Concrete playlist query owner | Accepted narrowly in [#591](https://github.com/aladh/Spotty/pull/591). `PlaylistStore` owns selection, cached/live reads, retention, freshness/refusal and entity publication; `PlaylistFeature` composes query and the existing mutation owner. Album/artist/discography keep their named shared owners. Approximately 143 net production lines improved locality; no size/CPU/RSS reduction is claimed. |
| Move all catalog orchestration behind a new client/module | Reject as a required cutover. Keep `CatalogReadFlights`, `RetainedCatalogRoutes`, `CatalogEntityObservation`, provider/SQLite and `PlaylistMutationController` while they serve named consumers. Any later slice needs real profile/reconnect, registration/read/apply/ack, persistence, dispatch and UI outcomes, with an explicit deletion plan. |
| Terminal fixture owners and owner settlement | Accepted in [#602](https://github.com/aladh/Spotty/pull/602), [#604](https://github.com/aladh/Spotty/pull/604), [#605](https://github.com/aladh/Spotty/pull/605) and [#606](https://github.com/aladh/Spotty/pull/606). Gates close current/future calls; cleanup joins accepted work. Flight-worker joins include owner completion instead of inferring settlement from provider return. Seeded failure/restoration and complete native evidence remain in the child issues. |
| Focused package selection and bounded test-host attribution | Accepted in [#603](https://github.com/aladh/Spotty/pull/603). Actual Swift 6.3.3/6.4 prove exact functions and dependency closures, engine-free isolation, unchanged app locks and explicitly supported optimized probes. No broadening/retry after compiler failure. The original stall cause remains unclassified; later loopback and harness failures have distinct dispositions. |
| Catalog memory optimization | No production change justified by the completed isolated investigation. Thirty matched-input ambient primary processes and six separate instrumented processes identify expected rows, contribution/export dictionaries and bounded memberships. Account retirement releases their graphs. Reusable capacity, allocator/framework baselines and unassigned transient bytes are explicit; there is no whole-app or shipping improvement claim. |
| CI scheduling/cache improvements | Final under the user's revised [#587](https://github.com/aladh/Spotty/issues/587) acceptance: app 194 → 155 seconds (20.10%), engine 456 → 243 seconds (46.71%). The original 50% target was missed. Historical three-sample observations establish no p95, CPU/RSS or billed-cost savings and do not describe later expanded verification workloads. |
| Timestamp repair | Preserve and defer. Precision-loss preparation established no independently necessary correctness change here. No further CI-speed cycle or timestamp merge is authorized by these results. |
| XPC/helper deployment, Swift engine replacement, secure-store migration, API/web/remote product or rendering rewrite | Retain current choices; outside this scope. No measured need, engine parity/deletion proof, signing/migration authorization or changed product agreement was established. #424/#465/#470 remain references. Preserve Spotify familiarity and native interaction. |

All accepted changes preserve synchronous admission; independent account, reconnect, engine, route
and write-authority fences; duplicate occurrence identity; complete metadata read/apply/ack;
profile admission of saved content; uncertain-write handling; and offscreen invalidation/reconciliation.
Cached data cannot manufacture playback, collection or mutation authority.

The preserved nonshipping AccountWorkspace experiment reports 18 functions/21 expanded executions,
two caught/restored guard faults and a compiled public caller on Swift 6.4. Its four-query,
eight-subscriber and 4,096-row limits bound prototype counts, not memory bytes. Its tiny synthetic
runtime proves no production performance benefit. It did not verify implicit drop without close,
production SQLite/profile/reconnect/engine integration, UI outcomes, migration or rollback.
No prototype cutover is accepted.

The published playback-v0.2.1 consumer pin remains unchanged. No engine release, app release,
live-account action, audio, credential cleanup or signing/security change resulted from this
investigation. Synthetic state/lifetime evidence establishes neither visual/accessibility parity
nor live Spotify behavior. Broader ideas are outside this session, not hidden unfinished acceptance.
