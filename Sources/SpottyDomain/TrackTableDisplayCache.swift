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
        return true
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
        // Classify each sort field once, not once per row comparison. Date ordering keeps
        // missing values last in either direction; other fields retain their supplied comparator.
        let comparisons = sortOrder.map { (comparator: $0, isDateAdded: $0.isDateAdded) }
        // Move small indexes while sorting, then materialize the ordered records once.
        // Source offset is the final tie-breaker for equal values and duplicate occurrences.
        let sortedIndices = rows.indices.sorted { left, right in
            let lhs = rows[left]
            let rhs = rows[right]
            for (comparator, isDateAdded) in comparisons {
                let result =
                    isDateAdded
                    ? compareOptional(lhs.track.addedAt, rhs.track.addedAt, order: comparator.order)
                    : comparator.compare(lhs, rhs)
                switch result {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: continue
                }
            }
            return lhs.sourceIndex < rhs.sourceIndex
        }
        return sortedIndices.map { rows[$0] }
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
