import Foundation
import SpottyDomain

/// Identifies one admitted account lifetime. This value is never persisted.
public struct CatalogStorageScope: Equatable, Sendable {
    public let id: UUID

    public init(id: UUID = UUID()) {
        self.id = id
    }
}

public enum CatalogStorageError: Error, Equatable, Sendable {
    case staleScope
    case retired
    case accountInUse
    case invalidInput
    case unsafeStorageLocation
    case unsupportedSchema(Int32)
    case database(Int32)
    case invalidStoredData
    case filesystem
}

public struct CatalogRetentionLimits: Sendable {
    public let entities: Int
    public let collections: Int
    public let occurrencesPerCollection: Int
    public let pageSize: Int
    public let recordBytes: Int
    public let databaseBytes: Int

    public init(
        entities: Int = 20_000,
        collections: Int = 32,
        occurrencesPerCollection: Int = 10_000,
        pageSize: Int = 500,
        recordBytes: Int = 65_536,
        databaseBytes: Int = 128 * 1_024 * 1_024
    ) {
        self.entities = entities
        self.collections = collections
        self.occurrencesPerCollection = occurrencesPerCollection
        self.pageSize = pageSize
        self.recordBytes = recordBytes
        self.databaseBytes = databaseBytes
    }
}

public enum CatalogCollectionCompleteness: Int, Codable, Sendable {
    case partial
    case complete
}

/// Browsing identity is separate from the requested market identity and playable URI.
/// A stored server UID is historical evidence only; writes still require fresh validation.
public struct CatalogOccurrence: Identifiable, Equatable, Sendable {
    public let id: String
    public let requestedURI: String
    public let serverUID: String?
    public let track: CatalogTrack

    public init(id: String, requestedURI: String, serverUID: String? = nil, track: CatalogTrack) {
        self.id = id
        self.requestedURI = requestedURI
        self.serverUID = serverUID
        self.track = track
    }

    /// Stable display identities for repeated requested tracks when no server identity is known.
    /// These IDs distinguish duplicates but cannot identify which indistinguishable duplicate moved.
    /// They must never authorize playlist or queue mutations.
    public static func browsingRows(_ tracks: [CatalogTrack]) -> [CatalogOccurrence] {
        let idCounts = tracks.reduce(into: [String: Int]()) { $0[$1.id, default: 0] += 1 }
        var usedIDs = Set(tracks.filter { !$0.id.isEmpty && idCounts[$0.id] == 1 }.map(\.id))
        var counts: [String: Int] = [:]
        return tracks.map { track in
            var displayID = track.id
            if displayID.isEmpty || idCounts[displayID] != 1 {
                var ordinal = counts[track.uri, default: 0]
                repeat {
                    displayID = "catalog:\(track.uri.utf8.count):\(track.uri):\(ordinal)"
                    ordinal += 1
                } while usedIDs.contains(displayID)
                counts[track.uri] = ordinal
                usedIDs.insert(displayID)
            }
            let row = CatalogTrack(
                id: displayID, uri: track.uri, title: track.title, artist: track.artist,
                album: track.album, duration: track.duration, artworkURL: track.artworkURL,
                addedAt: track.addedAt, artists: track.artists, albumItem: track.albumItem,
                occurrenceUID: track.occurrenceUID
            )
            return CatalogOccurrence(
                id: displayID, requestedURI: track.uri, serverUID: track.occurrenceUID, track: row
            )
        }
    }
}

public struct CatalogCollectionMetadata: Equatable, Sendable {
    public let item: CatalogItem?
    public let description: String
    public let ownerURI: String?
    public let releaseDate: String

    public init(item: CatalogItem? = nil, description: String = "", ownerURI: String? = nil, releaseDate: String = "") {
        self.item = item
        self.description = description
        self.ownerURI = ownerURI
        self.releaseDate = releaseDate
    }
}

/// A refresh replaces a whole bounded browsing result, never the live Connect queue.
public struct CatalogCollectionWrite: Sendable {
    public let key: String
    public let occurrences: [CatalogOccurrence]
    public let completeness: CatalogCollectionCompleteness
    public let revision: String?
    public let fetchedAt: Date
    public let metadata: CatalogCollectionMetadata

    public init(
        key: String,
        occurrences: [CatalogOccurrence],
        completeness: CatalogCollectionCompleteness,
        revision: String? = nil,
        fetchedAt: Date,
        metadata: CatalogCollectionMetadata = CatalogCollectionMetadata()
    ) {
        self.key = key
        self.occurrences = occurrences
        self.completeness = completeness
        self.revision = revision
        self.fetchedAt = fetchedAt
        self.metadata = metadata
    }
}

public struct CatalogCollectionPage: Sendable {
    public let key: String
    public let occurrences: [CatalogOccurrence]
    public let offset: Int
    public let totalCount: Int
    public let completeness: CatalogCollectionCompleteness
    public let revision: String?
    public let fetchedAt: Date
    public let metadata: CatalogCollectionMetadata

    public var hasMore: Bool { offset + occurrences.count < totalCount }
}

/// IDs of effective changes from one transaction, including retention evictions.
/// Freshness changes invalidate a query without falsely reporting track metadata changes.
public struct CatalogStorageChanges: Equatable, Sendable {
    public var trackURIs: Set<String> = []
    public var itemURIs: Set<String> = []
    public var collectionKeys: Set<String> = []
    /// Rejected completeness/freshness is distinct from an accepted effective no-op. Consumers
    /// must not hydrate fresh live rows from a collection that this transaction did not accept.
    public var collectionWriteRejected = false

    public init() {}
    public var isEmpty: Bool { trackURIs.isEmpty && itemURIs.isEmpty && collectionKeys.isEmpty }
}
