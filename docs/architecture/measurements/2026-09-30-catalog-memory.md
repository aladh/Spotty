# Isolated catalog retention — 2026-09-30

The synthetic investigation found expected row, metadata and membership allocations, with account
retirement releasing their graphs. It does not demonstrate a problem warranting a production
optimization. Keep the existing owners, lazy export and retention policy; add no cache or CI memory
threshold. This describes optimized diagnostic test processes, not shipping or whole-app memory.

[Structured report](2026-09-30-catalog-memory.json) ·
[Thirty primary samples](2026-09-30-catalog-memory-primary.jsonl) ·
[Separate allocation census](2026-09-30-catalog-memory-attribution.jsonl)

## Inputs and protocol

Production baseline: `88a4a772a2207c17c88f22443e309e259183724d`, plus the opt-in
[fixture](../../../Tests/SpottyBoundaryTests/CatalogRetainedMemoryMeasurementChecks.swift), SHA-256
`70586e6c5f0381b60ec33b66569bcc76de1f7e77a506b6eb0ef3d826a765e927`.
No production candidate was tested. Swift 6.4/Xcode 27, macOS 27.0.1, ten logical processors,
32 GiB, actual macOS 26.5 SDK. The published `playback-v0.2.1` pin, engine bytes, source,
locks, produced bundle, helper host, compiler metadata and scratch/cache context were bound and
rechecked. No local engine override, live account, audio, application launch or release.

The [supported native profile](../../development/runtime-acceptance.md#measurements) uses Debug
`-O -enable-testing -no-whole-module-optimization -DSPOTTY_BROWSING_OPTIMIZED`; actual
metadata proved all twelve compiled modules' effective flags, including DEBUG. The fixture is not
shipping WMO. Build and six-cell functional qualification preceded sampling.

Five fresh native processes ran each same-selection/A–B × 500/10,000/40,000 cell in frozen
randomized order (seed 586590): thirty samples, 128.68 seconds. Ten checkpoints separate initial
load, lazy export, preparation, eviction, invalidation, populated retirement and owner release.
Two 10,000-row routes exercise the shipping 20,000-row retention bound; 500-row eviction fills the
20-route bound. Forty-thousand-row A/B visits cannot restore retained content: ten prepare/reload
windows are reported separately from hundred-iteration retained preparation. Duplicate occurrence
identity, route versions and atomic old/new observation were asserted.

Two earlier quiet-load series stopped at slots 2 and 7; their failures remain rejected. The user
accepted ambient conditions. A separately frozen ambient protocol retained every new slot, recorded
external load/variability, and preserved native/provenance/cleanup requirements. External CPU ranged
0.11–1.34 core equivalents (median 0.17); machine busy fraction ranged 19.7–32.3%. No competing
compiler CPU was observed, swap remained zero and no thermal restriction was reported. These are
matched-input ambient descriptions, not a quiet baseline or causal speed comparison.

## Primary observations

Medians; MiB for current footprint/allocator values. Full phase values, variability, cumulative peak
RSS, CPU windows and receipt hashes are in the datasets. Resident, footprint, malloc in-use and
reserved bytes are distinct; peak RSS never measures release.

| Workload | Rows/route | Preparation CPU, seconds | Post-load footprint | In-use load | In-use after preparation | In-use retirement |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Same | 500 | 0.000269 | 7.22 | 1.04 | 1.27 | 0.64 |
| Same | 10,000 | 0.000305 | 27.22 | 14.47 | 17.86 | 0.64 |
| Same | 40,000 | 0.000169 | 45.74 | 32.44 | 45.96 | 0.64 |
| A/B | 500 | 0.266705 | 7.89 | 1.32 | 1.58 | 0.64 |
| A/B | 10,000 | 5.722097 | 27.30 | 14.47 | 17.81 | 0.62 |
| A/B oversized | 40,000 | 1.054385 | 53.16 | 35.91 | 51.89 | 0.66 |

The last row excludes ten reloads from its preparation CPU. No comparison with historical
three-sample CPU or cumulative-RSS archives is made.

## Allocation attribution and limits

Six separately instrumented processes completed 60 exact-PID gates in 172.69 seconds. Installed
`heap --noContent`, `vmmap -summary`, `footprint` and at most two representative `malloc_history`
addresses per gate passed. Birth/image/ancestry were validated before/after attachment and before
acknowledgement; raw addresses/stacks stay local. Complete original native validation and kernel
death evidence accompany each sample; missing identity was never accepted as death.

For two 10,000-row routes, the census identified two row arrays totaling 6,045,696 bytes, a
3,555,328-byte contribution dictionary, and another 3,555,328-byte dictionary after lazy export.
Histories identify `CatalogTrackContributions.replacing` and `browsingMetadata` allocation paths.
Membership/dirty sets, Observation state and test/framework baselines are separately recorded.
Empty export/dirty-set capacity can survive route invalidation; account reset removes it.
Every cell's retirement census contains no catalog row array or metadata dictionary, and every weak
owner-release check passed. Current footprint can retain allocator pages after live graphs disappear.

Checkpoint census and two histories cannot assign every transient or peak byte. Observation's
batch-local keypaths are distinguished from settled retention; no exhaustive transient-byte total is
claimed. Other typed allocations, strings and allocator/framework costs remain partly unassigned.
Instrumented baseline/scheduling/bytes are never pooled with primary data. Global stack logging
crashed Python supervision; an initial direct launch lacked Testing.framework. Both original failures
are preserved. Final logging reached only the native helper with the observed SwiftPM library/SDK
context; logging's own footprint-tagging warning further limits instrumented footprint interpretation.

## Reproduction and preservation

The fixture requires a bounded owned controller, including live exact-function/host admission before
its first checkpoint. Its native contributor command is the supported Boundary command with filter
`CatalogRetainedMemoryMeasurementTests/measureIsolatedCatalogRetention`, the four report/nonce/
workload/rows environment values, and unchanged `--skip-build` inputs for samples. Attribution adds
exact-PID gates and leaf-only logging. Report/exit success alone is insufficient admission.

This investigation did not add a self-service benchmark framework. Frozen controller/protocol
sources, configs, build metadata, originals and rejected attempts remain in the local
`spotty-586-successor-4vgkmg57` packet; public datasets bind their hashes and expose sanitized results.
The original `.build/handoff-586-memory` preparation and prior performance archives remain preserved.
Future reproduction must requalify its source/image/tool permissions and process ownership, never
reuse these receipts to authorize a new run.
