# ADR 009: Account-scoped persistent catalog and retained browsing routes

Status: accepted on 2026-09-12.

## Context

A selected-page store loses useful content when another page replaces it. Browsing needs stable
track identity, ordered duplicate occurrences, bounded reuse, and a clear distinction between
saved metadata and current authority. Persisting account-derived content also introduces a storage
and deletion obligation that an in-memory cache did not have.

## Decision

Use SQLite through the serialized `SpottyCatalogStorage` owner for typed catalog entities,
collection membership, completeness, and freshness. Track identity remains the requested/market
Spotify URI. Ordered occurrences have separate display identity; duplicate URIs are preserved.
Stored server UIDs and playlist ownership are historical metadata and cannot authorize mutations.
Partial or older results must not replace an accepted complete collection. Transactions report
changed entity and collection IDs; identical effective metadata produces no entity change.

The runtime's catalog provider opens a partition only after a current live profile verifies the
account. A stored selector, account hash, or cached playlist owner is not account admission.
The production fallback retains complete playlist and album browsing results; other catalog
surfaces continue through the live gateway. Offline, timeout, and throttled reads can return a
complete saved result with cached freshness. Credential refusal, cancellation, and a retired
account cannot be hidden by a cache hit. An unavailable, corrupt, or unsupported database leaves
live browsing available without trusting or silently migrating unknown stored content.

Each account database has explicit entity, collection, occurrence, page, record, and file-size
bounds. Directory and file permissions are private to the macOS user; storage excludes grants,
raw Spotify responses, audio, and artwork bytes. Account lifetime tokens are not persisted.
Sign-out fences admission before deleting catalog content and SQLite sidecars. Failed deletion
keeps the owner fenced and reports failure; ordinary process termination closes the database for
later reuse. Empty ownership-lock files may remain. Deletion is logical removal, not forensic
erasure. [Privacy](../../../PRIVACY.md#local-storage) owns the user-facing storage disclosure.

Presentation keeps a separate bounded set of completed playlist, album, and artist routes for
synchronous revisits. These snapshots preserve collection versions and restore window-local search,
selection, sort, and scroll state. They are retired on account replacement. Reconnect can preserve
useful rows, but saved or failed-refresh content stays visibly stale and cannot enable occurrence
removal. A playlist write that succeeds, or whose admitted outcome becomes uncertain or cancelled,
invalidates its retained route even when another page is open. A cancelled reconciliation cannot
turn the previous rows into fresh authority.

Playlist and album stores subscribe to a bounded set of track URIs across their active and retained
routes through the [entity query contract](../../../Sources/SpottyRuntimeContracts/CatalogEntityQueries.swift).
Database transactions publish changes only for requested entities with changed metadata. Dirty
entity IDs remain pending until acknowledged, so coalescing notifications cannot lose an update.
Presentation assembles bounded pages from one revision and account lifetime before applying any
metadata; a superseded revision or retired account cannot publish a partial result.

Entity updates replace labels and other track metadata while preserving requested URI, display
occurrence identity, server occurrence UID, source order, date added, collection freshness, and
ownership. For example, metadata learned on album B updates a retained playlist A containing the
same track without reloading A. Only collections with changed effective metadata receive a new
version; unrelated collections and playback timeline observation stay unchanged. An entity update
does not grant fresh collection or mutation authority.

Artwork has a separate account-scoped memory owner rather than being stored in SQLite. Source
fetches are shared by size variants and artwork-derived header tint; decoding uses an independent
worker. The pipeline bounds retained source, encoded-thumbnail, and decoded-pixel bytes, rejects
oversized inputs, and does not use a shared response cache. Retirement cancels work, clears memory,
and rejects old completions. Reusing source bytes establishes an ownership and request-sharing
invariant, not a claim about the old framework cache's network traffic or measured speed.

Live Connect queue order, playback ownership, and command admission remain runtime facts. The
catalog supplies browsing and labels; it never reconstructs queue authority from disk. This adds
no downloaded music or offline playback. New windows still start on Home; route interaction state
is not restored across launches.

## Tradeoffs and revisit conditions

The synchronous route cache and serialized database serve different latency needs, so their
freshness and invalidation rules must agree. Playlist and album entity subscriptions refresh
metadata; ordered membership and freshness remain with the complete collection result. Other
catalog surfaces still use their existing live presentation and metadata owners. A whole-result
fallback must reject mixed revisions while paging its database read.

The storage format and retention limits are owned by
[`SpottyCatalogStorage`](../../../Sources/SpottyCatalogStorage), not duplicated in feature stores.
Broader persistent search/home/library/artist queries, on-disk artwork retention, or subscriptions
that change collection membership require their own measured benefit and privacy/lifetime
verification.
