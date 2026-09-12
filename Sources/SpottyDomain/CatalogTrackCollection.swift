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

    /// A provider can lack occurrence identity even when its entity URI is known. Keep every
    /// duplicate independently selectable; generated display IDs never create mutation authority.
    /// An ordinal only identifies indistinguishable rows within this source ordering.
    private static func normalizedOccurrences(_ tracks: [CatalogTrack]) -> [CatalogTrack] {
        let displayCounts = Dictionary(tracks.map { ($0.id, 1) }, uniquingKeysWith: +)
        let uidCounts = Dictionary(tracks.compactMap(\.occurrenceUID).map { ($0, 1) }, uniquingKeysWith: +)
        guard displayCounts.values.contains(where: { $0 > 1 }) || uidCounts.values.contains(where: { $0 > 1 }) else {
            return tracks
        }
        var usedIDs = Set(tracks.filter { displayCounts[$0.id] == 1 }.map(\.id))
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
