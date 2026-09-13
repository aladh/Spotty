//
//  TrackTableDisplayCache.swift
//  Spotty
//

import Foundation

/// Cached projection of catalog rows for a native `Table` sort order.
///
/// Recompute when the collection version or SwiftUI comparators change.
public struct TrackTableDisplayCache: Sendable {
    public private(set) var rows: [TrackTableRow]
    /// One-based display positions keyed by the immutable source occurrence offset.
    ///
    /// `sourceIndex` remains the identity used for deterministic tie-breaking and mutation
    /// ordering; this separate projection lets table cells render their current sorted position
    /// without scanning the displayed rows for every cell.
    private var displayPositions: [Int: Int]
    private var version: UUID
    private var sortOrder: [KeyPathComparator<TrackTableRow>]

    public init(
        _ collection: CatalogTrackCollection = CatalogTrackCollection(),
        sortOrder: [KeyPathComparator<TrackTableRow>] = []
    ) {
        version = collection.version
        self.sortOrder = sortOrder
        rows = Self.projected(
            tracks: collection.tracks,
            sortOrder: sortOrder
        )
        displayPositions = Self.displayPositions(for: rows)
    }

    /// Returns whether `rows` were rebuilt from `collection` and `sortOrder`.
    @discardableResult
    public mutating func update(
        _ collection: CatalogTrackCollection,
        sortOrder: [KeyPathComparator<TrackTableRow>]
    ) -> Bool {
        guard version != collection.version || self.sortOrder != sortOrder else {
            return false
        }
        version = collection.version
        self.sortOrder = sortOrder
        rows = Self.projected(
            tracks: collection.tracks,
            sortOrder: sortOrder
        )
        displayPositions = Self.displayPositions(for: rows)
        return true
    }

    /// Returns the one-based position of a row in the current displayed projection.
    ///
    /// The map is rebuilt alongside `rows`, so this remains constant-time even for large
    /// playlists and does not conflate display position with source occurrence identity.
    public func displayPosition(for row: TrackTableRow) -> Int {
        displayPositions[row.sourceIndex] ?? row.sourceIndex + 1
    }

    public static func prunedSelection(
        _ selection: Set<CatalogTrack.ID>,
        from tracks: [CatalogTrack]
    ) -> Set<CatalogTrack.ID> {
        selection.intersection(Set(tracks.map(\.id)))
    }

    private static func projected(
        tracks: [CatalogTrack],
        sortOrder: [KeyPathComparator<TrackTableRow>]
    ) -> [TrackTableRow] {
        let rows = tracks.enumerated().map { index, track in
            TrackTableRow(track: track, sourceIndex: index)
        }
        guard !sortOrder.isEmpty else { return rows }
        // The standard library does not promise a stable sort. Source offset is the final
        // tie-breaker so duplicate occurrences and equal or missing values retain playlist order.
        return rows.sorted { lhs, rhs in
            for comparator in sortOrder {
                switch compare(lhs, rhs, using: comparator) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: continue
                }
            }
            return lhs.sourceIndex < rhs.sourceIndex
        }
    }

    private static func displayPositions(for rows: [TrackTableRow]) -> [Int: Int] {
        Dictionary(
            rows.enumerated().map { index, row in (row.sourceIndex, index + 1) },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    private static func compare(
        _ lhs: TrackTableRow,
        _ rhs: TrackTableRow,
        using comparator: KeyPathComparator<TrackTableRow>
    ) -> ComparisonResult {
        if comparator.isDateAdded {
            return compareOptional(lhs.track.addedAt, rhs.track.addedAt, order: comparator.order)
        }
        return comparator.compare(lhs, rhs)
    }

    private static func compareOptional<Value: Comparable>(
        _ lhs: Value?,
        _ rhs: Value?,
        order: SortOrder
    ) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (.some(lhs), .some(rhs)):
            if lhs == rhs { return .orderedSame }
            let ascending: ComparisonResult = lhs < rhs ? .orderedAscending : .orderedDescending
            return order == .forward ? ascending : ascending.reversed
        case (.some, .none): return .orderedAscending
        case (.none, .some): return .orderedDescending
        case (.none, .none): return .orderedSame
        }
    }
}

private extension ComparisonResult {
    var reversed: ComparisonResult {
        switch self {
        case .orderedAscending: .orderedDescending
        case .orderedDescending: .orderedAscending
        case .orderedSame: .orderedSame
        }
    }
}
