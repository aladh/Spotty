import Foundation

/// A complete, bounded walk of one offset-based Spotify endpoint. Callers supply raw entry
/// counts separately from decoded items so unavailable entities still advance the offset.
nonisolated enum Pagination {
    /// Maximum consumed pages, including a supplied first page. HTTP retries and the library's
    /// aggregate budget across folders are owned by their respective request boundaries.
    static let maximumPageCount = 500

    enum Failure: Error, Equatable, Sendable, LocalizedError {
        case pageLimitReached
        case incompleteCollection

        var errorDescription: String? {
            switch self {
            case .pageLimitReached: "Spotify pagination exceeded the request limit"
            case .incompleteCollection: "Spotify returned an incomplete collection"
            }
        }
    }

    struct Page<Item: Sendable>: Sendable {
        let items: [Item]
        let pageEntryCount: Int
        let totalCount: Int?
    }

    /// Retains the first reported total and preserves item order and duplicates. Failure never
    /// publishes a partial collection. A prefetched header page is consumed without refetching it.
    static func collect<Item: Sendable>(
        firstPage: Page<Item>? = nil,
        fetchPage: @Sendable (Int) async throws -> Page<Item>
    ) async throws -> [Item] {
        var items: [Item] = []
        var offset = 0
        var total: Int?

        for pageIndex in 0..<maximumPageCount {
            try Task.checkCancellation()
            let page: Page<Item>
            if pageIndex == 0, let firstPage {
                page = firstPage
            } else {
                page = try await fetchPage(offset)
            }
            try Task.checkCancellation()

            if let reported = page.totalCount {
                guard reported >= 0, total == nil || total == reported else {
                    throw PartnerAPIError.pagination(.incompleteCollection)
                }
                total = reported
            }
            let (end, overflow) = offset.addingReportingOverflow(page.pageEntryCount)
            guard page.pageEntryCount >= page.items.count, !overflow,
                total.map({ end <= $0 }) ?? true
            else { throw PartnerAPIError.pagination(.incompleteCollection) }

            items.append(contentsOf: page.items)
            if let total, end == total { return items }
            if page.pageEntryCount == 0 {
                guard total == nil else { throw PartnerAPIError.pagination(.incompleteCollection) }
                return items
            }
            // A positive raw count and checked addition guarantee strict forward progress.
            offset = end
        }
        throw PartnerAPIError.pagination(.pageLimitReached)
    }
}
