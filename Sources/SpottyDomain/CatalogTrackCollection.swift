//
//  CatalogTrackCollection.swift
//  Spotty
//

import Foundation

/// Authoritative catalog rows plus one opaque version per assignment.
///
/// `init` and `replace(_:)` each mint a new `version`. Copies share a version until
/// one of them replaces. `TrackTable` caches display order on `version` plus SwiftUI
/// `sortOrder`, not on row equality.
public struct CatalogTrackCollection: Sendable {
    public private(set) var tracks: [CatalogTrack]
    public private(set) var version: UUID

    public init(tracks: [CatalogTrack] = []) {
        self.tracks = Self.normalizedOccurrences(tracks)
        version = UUID()
    }

    public mutating func replace(_ tracks: [CatalogTrack]) {
        self.tracks = Self.normalizedOccurrences(tracks)
        version = UUID()
    }

    /// Enrich matching occurrences without changing membership or collection-owned identity.
    /// A nil result preserves the caller's collection version when no metadata changed.
    public func applyingMetadata(_ entities: [String: CatalogTrackMetadata]) -> CatalogTrackCollection? {
        guard !entities.isEmpty else { return nil }
        var changed = false
        // Share the original array until a changed occurrence requires a copy.
        var updatedTracks = tracks
        for index in tracks.indices {
            let occurrence = tracks[index]
            guard let entity = entities[occurrence.uri], entity.uri == occurrence.uri else { continue }
            let updated = CatalogTrack(
                id: occurrence.id, uri: occurrence.uri, title: entity.title, artist: entity.artist,
                album: entity.album, duration: entity.duration, artworkURL: entity.artworkURL,
                addedAt: occurrence.addedAt, artists: entity.artists, albumItem: entity.albumItem,
                occurrenceUID: occurrence.occurrenceUID
            ).fillingMissingLinks(from: occurrence)
            if updated != occurrence {
                updatedTracks[index] = updated
                changed = true
            }
        }
        guard changed else { return nil }
        // Enrichment preserves collection-owned identity, so it cannot require normalization.
        var enriched = self
        enriched.tracks = updatedTracks
        enriched.version = UUID()
        return enriched
    }

    /// A provider can lack occurrence identity even when its entity URI is known. Keep every
    /// duplicate independently selectable; generated display IDs never create mutation authority.
    /// An ordinal only identifies indistinguishable rows within this source ordering.
    private static func normalizedOccurrences(_ tracks: [CatalogTrack]) -> [CatalogTrack] {
        var displayCounts = [String: Int](minimumCapacity: tracks.count)
        var uidCount = 0
        for track in tracks {
            displayCounts[track.id, default: 0] += 1
            if track.occurrenceUID != nil { uidCount += 1 }
        }
        // Count optional UIDs before allocating their table: albums usually have none, while
        // large playlists avoid repeated growth without constructing temporary row/UID arrays.
        var uidCounts = [String: Int](minimumCapacity: uidCount)
        if uidCount > 0 {
            for track in tracks {
                if let uid = track.occurrenceUID { uidCounts[uid, default: 0] += 1 }
            }
        }
        guard displayCounts.values.contains(where: { $0 > 1 }) || uidCounts.values.contains(where: { $0 > 1 }) else {
            return tracks
        }
        var usedIDs = Set<String>(minimumCapacity: tracks.count)
        for (id, count) in displayCounts where count == 1 { usedIDs.insert(id) }
        var ordinals: [String: Int] = [:]
        return tracks.map { track in
            var displayID = track.id
            if displayCounts[track.id, default: 0] > 1 {
                let ordinal = ordinals[track.id, default: 0]
                ordinals[track.id] = ordinal + 1
                let base = "display:\(track.id.utf8.count):\(track.id):\(ordinal)"
                var candidate = base
                var collision = 0
                while !usedIDs.insert(candidate).inserted {
                    collision += 1
                    candidate = "\(base):\(collision)"
                }
                displayID = candidate
            }
            let uid = track.occurrenceUID.flatMap { uidCounts[$0] == 1 ? $0 : nil }
            guard displayID != track.id || uid != track.occurrenceUID else { return track }
            return CatalogTrack(
                id: displayID, uri: track.uri, title: track.title, artist: track.artist, album: track.album,
                duration: track.duration, artworkURL: track.artworkURL, addedAt: track.addedAt,
                artists: track.artists, albumItem: track.albumItem, occurrenceUID: uid)
        }
    }
}
