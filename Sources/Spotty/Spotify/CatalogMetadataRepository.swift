//
//  CatalogMetadataRepository.swift
//  Spotty
//
//  Session-scoped catalog lookup.
//

import SpottyDomain
import SpottyRuntimeContracts
import Foundation
import Observation

@MainActor
@Observable
final class CatalogMetadataRepository {
    typealias TrackSource = CatalogTrackContributions.Source

    enum ItemSource: Int, CaseIterable {
        case library
        case home
        case search
    }

    /// Changes only when the effective genuine browsing labels exported to the runtime change.
    /// Playback publications must not feed themselves back as higher-priority browsing input.
    @ObservationIgnored private var runtimeTracksRevision: UInt64 = 0
    @ObservationIgnored private var runtimeEntities: [String: CatalogTrackMetadata] = [:]
    @ObservationIgnored private var dirtyRuntimeURIs: Set<String> = []

    @ObservationIgnored private let contentObservation = ObservationRegistrar()
    @ObservationIgnored private let session: CatalogSessionAvailability
    @ObservationIgnored private var trackContributions = CatalogTrackContributions()
    @ObservationIgnored private var itemsBySource: [ItemSource: [String: CatalogItem]] = [:]
    @ObservationIgnored private var contentEpoch: UInt64 = 0

    init(session: CatalogSessionAvailability) {
        self.session = session
    }

    func reset() {
        clearContent(for: session.accountEpoch)
    }

    func replaceTracks(_ tracks: [CatalogTrack], from source: TrackSource) {
        guard acceptCurrentSessionWrite() else { return }
        publishTracks(trackContributions.replacing(tracks, from: source))
    }

    func replaceItems(_ items: [CatalogItem], from source: ItemSource) {
        guard acceptCurrentSessionWrite() else { return }
        let replacement = Dictionary(
            items.lazy.map { ($0.uri, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let affectedURIs = Self.changedURIs(from: itemsBySource[source] ?? [:], to: replacement)
        var updated = itemsBySource
        updated[source] = replacement
        publishItems(updated, affectedURIs: affectedURIs)
    }

    /// Immutable complete input, prepared lazily from only changed entities. Copies share their
    /// lookup with the runtime; the first subsequent edit pays Swift's copy-on-write cost.
    /// Compatible links already exported within this account survive a partial browsing update.
    var browsingMetadata: BrowsingMetadataSnapshot {
        guard contentEpoch == session.accountEpoch else {
            return BrowsingMetadataSnapshot(
                accountEpoch: session.accountEpoch, revision: runtimeTracksRevision, tracks: [:])
        }
        for uri in dirtyRuntimeURIs {
            runtimeEntities[uri] = trackContributions.browsingTrack(for: uri)?
                .fillingMissingLinks(from: runtimeEntities[uri])
        }
        dirtyRuntimeURIs.removeAll(keepingCapacity: true)
        return BrowsingMetadataSnapshot(
            accountEpoch: contentEpoch, revision: runtimeTracksRevision, tracks: runtimeEntities)
    }

    func knownTrack(for uri: String) -> CatalogTrack? {
        self[track: uri]?.playbackTrack
    }

    func knownItem(for uri: String) -> CatalogItem? {
        self[item: uri]
    }

    // Subscript key paths carry the URI, including misses, without storing per-URI observer boxes
    // or per-reader caches. Track and item readers subscribe independently.
    private subscript(track uri: String) -> CatalogTrackMetadata? {
        contentObservation.access(self, keyPath: \.[track: uri])
        guard contentEpoch == session.accountEpoch else { return nil }
        return trackContributions.displayTrack(for: uri)
    }

    private subscript(item uri: String) -> CatalogItem? {
        contentObservation.access(self, keyPath: \.[item: uri])
        guard contentEpoch == session.accountEpoch else { return nil }
        return Self.item(for: uri, in: itemsBySource)
    }

    func displayInfo(for uri: String) -> (title: String, artist: String) {
        if let track = knownTrack(for: uri) {
            return (track.title, track.artist)
        }
        if let item = knownItem(for: uri) {
            return (item.title, item.subtitle)
        }
        let id = uri.split(separator: ":").last.map(String.init) ?? uri
        return ("Unknown track", id)
    }

    private func acceptCurrentSessionWrite() -> Bool {
        let snapshot = session.snapshot
        guard snapshot.isAvailable else { return false }
        if contentEpoch != snapshot.accountEpoch {
            clearContent(for: snapshot.accountEpoch)
        }
        return true
    }

    private func clearContent(for epoch: UInt64) {
        publishTracks(trackContributions.clearing())
        publishItems([:], affectedURIs: Set(itemsBySource.values.flatMap(\.keys)))
        runtimeEntities.removeAll(keepingCapacity: false)
        dirtyRuntimeURIs.removeAll(keepingCapacity: false)
        contentEpoch = epoch
    }

    private func publishTracks(_ replacement: CatalogTrackContributions.Replacement) {
        let changes: [KeyPath<CatalogMetadataRepository, CatalogTrackMetadata?>] =
            replacement.displayChangedURIs.map { \.[track: $0] }
        // Reuse each captured-URI key path across both notifications; keep the batch local.
        // Announce before committing the complete snapshot so callbacks see coherent old values.
        // Hidden source updates still commit, but do not wake unchanged lookups.
        for keyPath in changes { contentObservation.willSet(self, keyPath: keyPath) }
        trackContributions = replacement.next
        if !replacement.browsingInvalidatedURIs.isEmpty {
            runtimeTracksRevision &+= 1
            dirtyRuntimeURIs.formUnion(replacement.browsingInvalidatedURIs)
        }
        for keyPath in changes { contentObservation.didSet(self, keyPath: keyPath) }
    }

    private func publishItems(
        _ updated: [ItemSource: [String: CatalogItem]],
        affectedURIs: Set<String>
    ) {
        guard !affectedURIs.isEmpty else { return }
        let changes: [KeyPath<CatalogMetadataRepository, CatalogItem?>] = affectedURIs.compactMap { uri in
            guard Self.item(for: uri, in: itemsBySource) != Self.item(for: uri, in: updated) else { return nil }
            return \.[item: uri]
        }
        for keyPath in changes { contentObservation.willSet(self, keyPath: keyPath) }
        itemsBySource = updated
        for keyPath in changes { contentObservation.didSet(self, keyPath: keyPath) }
    }

    /// Compare source entries once; merge source precedence only for entries that changed.
    /// Hidden writes still reach publication so removing a higher-priority source reveals them.
    private static func changedURIs<Value: Equatable>(
        from previous: [String: Value], to replacement: [String: Value]
    ) -> Set<String> {
        var changed = Set<String>()
        for (uri, value) in replacement where previous[uri] != value { changed.insert(uri) }
        for uri in previous.keys where replacement[uri] == nil { changed.insert(uri) }
        return changed
    }

    private static func item(
        for uri: String,
        in items: [ItemSource: [String: CatalogItem]]
    ) -> CatalogItem? {
        for source in ItemSource.allCases.reversed() {
            if let item = items[source]?[uri] { return item }
        }
        return nil
    }

}
