import Foundation
import SpottyDomain

/// Entity observation changes metadata only. The caller retains ordered collection membership,
/// requested track identity, occurrence identifiers, and freshness from its collection result.
public protocol CatalogEntityQueryProviding: Sendable {
    func subscribeCatalogEntities(_ uris: Set<String>) async throws -> CatalogEntitySubscription
    func catalogEntityPage(
        _ token: CatalogEntitySubscriptionToken, revision: UInt64, offset: Int, limit: Int
    ) async throws -> CatalogEntityPage
    func acknowledgeCatalogEntities(_ token: CatalogEntitySubscriptionToken, revision: UInt64) async
    func unsubscribeCatalogEntities(_ token: CatalogEntitySubscriptionToken) async
}

public enum CatalogEntityQueryLimits {
    public static let maximumRequestedURIs = 20_000
    public static let maximumSubscriptions = 8
    public static let pageSize = 500
}

public enum CatalogEntityQueryFailure: Error, Equatable, Sendable {
    /// A newer invalidation or a retry of this revision will be delivered on the stream.
    case superseded
    case unavailable
    case invalidRequest
    case capacity
    case retired
}

public struct CatalogEntitySubscriptionToken: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let accountLifetime: UUID

    public init(id: UUID = UUID(), accountLifetime: UUID) {
        self.id = id
        self.accountLifetime = accountLifetime
    }
}

public struct CatalogEntitySubscription: Sendable {
    public let token: CatalogEntitySubscriptionToken
    public let updates: AsyncStream<CatalogEntityChange>

    public init(token: CatalogEntitySubscriptionToken, updates: AsyncStream<CatalogEntityChange>) {
        self.token = token
        self.updates = updates
    }
}

/// A bounded invalidation, not an unbounded entity payload. Acknowledgement clears only this
/// revision; unacknowledged changes remain included when newer updates coalesce in the stream.
public struct CatalogEntityChange: Codable, Equatable, Sendable {
    public let token: CatalogEntitySubscriptionToken
    public let revision: UInt64
    public let totalCount: Int

    public init(token: CatalogEntitySubscriptionToken, revision: UInt64, totalCount: Int) {
        self.token = token
        self.revision = revision
        self.totalCount = totalCount
    }
}

public struct CatalogEntityPage: Codable, Equatable, Sendable {
    public let token: CatalogEntitySubscriptionToken
    public let revision: UInt64
    public let offset: Int
    public let totalCount: Int
    /// Advance with this value even when some requested entities are absent from retention.
    public let nextOffset: Int
    /// Metadata is projected to the requested URI key, even when stored playback metadata was
    /// relinked. Row IDs, added dates and server occurrence UIDs are absent from these entities.
    public let tracks: [String: CatalogTrack]

    public init(
        token: CatalogEntitySubscriptionToken, revision: UInt64, offset: Int,
        totalCount: Int, nextOffset: Int, tracks: [String: CatalogTrack]
    ) {
        self.token = token
        self.revision = revision
        self.offset = offset
        self.totalCount = totalCount
        self.nextOffset = nextOffset
        self.tracks = tracks
    }
}
