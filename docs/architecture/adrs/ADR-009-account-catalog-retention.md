# ADR 009: Account-scoped persistent catalog and retained browsing routes

Status: accepted on 2026-09-12.

## Context

Browsing needs bounded reuse across navigation, stable track and occurrence identity, and a clear
distinction between saved metadata and current authority. Persistence additionally requires account
admission and deletion guarantees. Saved content must improve continuity without granting playback,
account, or mutation authority.

## Decision

[`SpottyCatalogStorage`](../../../Sources/SpottyCatalogStorage) serializes SQLite access and owns
storage format and retention limits. It stores typed entities, collection membership, completeness,
and freshness. Track identity remains the requested/market Spotify URI; ordered occurrences retain
separate display identity and duplicates. Stored server UIDs and ownership are historical metadata.
Partial or older results cannot replace an accepted complete collection.

Transactions report changed entities and collections; identical effective metadata produces no
entity notification. Shared entities and library snapshots retain observation dates across launches.
Older responses can supply collection membership without replacing newer entity metadata. Equal
dates use read admission order retained only until eviction or storage retirement. That order
advances after commit, including identical values, without being persisted or notifying subscribers.

The runtime's [`PersistentCatalogProvider`](../../../Sources/SpottySessionRuntime/PersistentCatalogProvider.swift)
opens a partition only after a current live profile verifies the account. A stored selector, account
hash, or owner cannot substitute. Activation and retirement carry account epochs: retirement fences
queued activations, and an older retirement cannot purge a replacement account. Logout retires
catalog and artwork admission before joining old connection work; durable grant adoption still
settles before credential removal.

Each database bounds entities, collections, occurrences, pages, records, and file size. Files and
directories are private to the macOS user. Storage excludes grants, raw Spotify responses, audio,
artwork bytes, and account lifetime tokens. Sign-out fences admission before deleting content and
SQLite sidecars. Failed deletion reports failure and keeps the owner fenced; normal termination
closes the database for reuse. Empty ownership-lock files may remain. Deletion is logical removal,
not forensic erasure; [privacy](../../../PRIVACY.md#local-storage) owns the user-facing disclosure.

After profile verification, complete saved library trees and playlist/album results can appear while
refreshing; retained in-memory routes take precedence. Home and other queries remain live. Library
traversal shares page/entry budgets across folders and rejects repeated folder identities. Live and
stored trees share [structural limits](../../../Sources/SpottyDomain/PlaylistLibraryNode.swift);
storage owns encoded-byte limits.

Offline, timeout, and throttled reads may return complete saved results with cached freshness.
Credential refusal, cancellation, and retirement cannot become cached success. Refusal clears the
affected detail and retained routes, fences suspended reads, and requires new profile proof.
Unavailable, corrupt, or unsupported storage leaves live browsing available without trusting or
migrating unknown content. [Catalog interaction](../../product/catalog-interaction.md) owns visible
loading, refusal, retention, and retry behavior.

[`CatalogDetailCoordinator`](../../../Sources/Spotty/Spotify/CatalogDetailCoordinator.swift) owns
selection, cached/live reads, bounded route retention, freshness, refusal, and entity merging.
Concrete projections expose content without controlling read lifecycle. Discography owns its bounded
album children, aggregate publication, and one union entity query; children publish cached/live
replacements immediately without private metadata repositories or subscriptions. Revisited routes preserve collection versions and
window-local search, selection, sort, and scroll; account replacement retires them. Reconnect may
preserve rows, but stale content cannot enable occurrence removal. Successful, uncertain, or cancelled
admitted playlist writes invalidate the retained route, even offscreen. Cancelled reconciliation
cannot restore fresh authority.

Shared read flights own admission, sharing, and loading settlement. Consumers cancel independently;
final cancellation or reset settles loading without awaiting timer or provider cooperation. Late completions
cannot publish or finish replacements. Cancelled admission cannot alter selection or debounce state.
Playlist writes retain separate session-valid reconciliation and latest-intent error reporting;
cancellation cannot establish a sent write's outcome. View tasks use the published session revision,
including coalesced reconnects.
Search's delayed scope includes its eventual fetch; immediate retries use a separate fetch scope.

Playlist and album stores observe bounded track URI sets across active and retained routes through
[entity queries](../../../Sources/SpottyRuntimeContracts/CatalogEntityQueries.swift). Transactions
notify only requested entities with changed metadata. Dirty IDs remain pending until acknowledged,
so coalescing cannot lose an update. A synchronous observation owner hides registration, dirty sets,
revision validation, acknowledgement, and write retries. The provider retains account admission and
cache write authority, assembling complete metadata through bounded storage
batches under one account and write revision. Presentation rechecks its route lifetime, applies,
then acknowledges. Cancellation, supersession, and retirement cannot publish partial results.
Presentation supplies immutable collections; the observation owner reuses one bounded URI set by
collection versions without retaining rows. Reuse still checks session admission and retries failed
queries. Metadata versions do not replace a query whose membership is unchanged.
Query registration and retirement serialize independently of reads. Replacements retire the old
token before admission; cancelled reads cannot retain subscription capacity. A late registration
is retired even after disposal. Whole collection replacement fences old reads even for unchanged URIs.

The domain merges metadata without changing requested URI, display identity, server UID, source
order, added date, freshness, or ownership. Only changed collections receive new versions; unrelated
collections and playback timeline observation remain unchanged. Entity updates never grant collection
or mutation authority. `CatalogTrackContributions` owns source precedence, compatible link learning,
and display/browsing deltas as a pure value. The desktop repository owns account admission, atomic
observation, and lazy export history; playback contributions never become browsing authority.

Artwork uses separate account-scoped memory, excluding a shared response cache. Size variants and
header tint share source fetches. Private workers await loading and decoding without retaining the
cache owner; capacity stays occupied until actual work settles. Retained bytes are bounded and
oversized inputs rejected. Cancellation settles each caller and cancels the final shared fetch,
preserving other variants. Retirement fences memory immediately and serializes loader cleanup;
replacement sources wait for that cleanup before loading. Late results cannot affect replacements.
SQLite stores no artwork bytes.

## Tradeoffs and revisit conditions

Storage returns complete bounded collections through non-suspending reads. Provider lifetime and
write-revision fences reject reads overlapping refreshes; entity observations additionally retain
incremental invalidations and acknowledgement. Persistent search/home/library expansion, on-disk
artwork, and subscriptions changing membership need measured benefits and privacy/lifetime checks.

Connect order, playback ownership, and command admission remain runtime facts; catalog data never
reconstructs queue authority. This adds no downloaded music or offline playback. New windows start
on Home, and route interaction state is not restored across launches.
