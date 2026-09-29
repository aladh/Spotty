import Testing
@testable import SpottyGateway
import SpottyTestSupport
import Synchronization
import Foundation

private enum WalkProbe: Error, Equatable {
    case boom
}

private final class OffsetRecorder: Sendable {
    private let recorded = Mutex<[Int]>([])
    var values: [Int] { recorded.withLock { $0 } }
    func record(_ offset: Int) { recorded.withLock { $0.append(offset) } }
}

@Suite("Pagination Collect")
struct PaginationCollectTests {
    @Test(arguments: [[nil, 3, 4], [nil, 3, 2], [3, 4], [3, 2], [nil, nil, 1], [-1], [nil, -1], [0]] as [[Int?]])
    func contradictoryTotalsCannotPublishACompleteCollection(totals: [Int?]) async {
        await #expect(throws: PartnerAPIError.pagination(.incompleteCollection)) {
            _ = try await Pagination.collect { offset in
                guard offset < totals.count else { throw WalkProbe.boom }
                return Pagination.Page(items: [offset], pageEntryCount: 1, totalCount: totals[offset])
            }
        }
    }

    @Test(arguments: [[nil, 3, nil], [3, nil, nil], [nil, nil, 3]] as [[Int?]], [false, true])
    func aConsistentTotalMayArriveLateOrBeOmitted(totals: [Int?], prefetched: Bool) async throws {
        let offsets = OffsetRecorder()
        let first = Pagination.Page(items: [0], pageEntryCount: 1, totalCount: totals[0])
        let items = try await Pagination.collect(firstPage: prefetched ? first : nil) { offset in
            offsets.record(offset)
            guard offset < totals.count else { throw WalkProbe.boom }
            return Pagination.Page(items: [offset], pageEntryCount: 1, totalCount: totals[offset])
        }
        #expect(items == [0, 1, 2])
        #expect(offsets.values == (prefetched ? [1, 2] : [0, 1, 2]))
    }

    @Test func completenessCountsUnavailableEntriesInsteadOfDecodedItems() async throws {
        let items = try await Pagination.collect { offset in
            if offset == 0 {
                return Pagination.Page(items: ["duplicate"], pageEntryCount: 2, totalCount: nil)
            }
            #expect(offset == 2)
            return Pagination.Page(items: ["duplicate"], pageEntryCount: 1, totalCount: 3)
        }
        #expect(items == ["duplicate", "duplicate"])
    }

    @Test(arguments: [nil, 1] as [Int?])
    func entriesCannotExceedAReportedTotal(firstTotal: Int?) async {
        await #expect(throws: PartnerAPIError.pagination(.incompleteCollection)) {
            _ = try await Pagination.collect { offset in
                Pagination.Page(
                    items: [offset, offset + 1], pageEntryCount: 2, totalCount: offset == 0 ? firstTotal : 3)
            }
        }
    }

    @Test(arguments: [-1, 0, 1])
    func rawEntryCountsCannotBeSmallerThanDecodedItems(count: Int) async {
        await #expect(throws: PartnerAPIError.pagination(.incompleteCollection)) {
            _ = try await Pagination.collect { _ in
                Pagination.Page(items: [0, 1], pageEntryCount: count, totalCount: 1)
            }
        }
    }

    @Test(arguments: ["known-total", "empty-page", "nonterminal"], [false, true])
    func actualPageLimitChargesPrefetchedPagesAndAllowsTerminalLastPage(ending: String, prefetched: Bool) async throws {
        let offsets = OffsetRecorder()
        let limit = Pagination.maximumPageCount
        let total: Int? = ending == "known-total" ? limit : nil
        let first = Pagination.Page(items: [0], pageEntryCount: 1, totalCount: total)
        let collect = {
            try await Pagination.collect(firstPage: prefetched ? first : nil) { offset in
                offsets.record(offset)
                guard offset < limit else { throw WalkProbe.boom }
                let items = ending == "empty-page" && offset == limit - 1 ? [] : [offset]
                return Pagination.Page(items: items, pageEntryCount: items.count, totalCount: total)
            }
        }
        if ending == "nonterminal" {
            await #expect(throws: PartnerAPIError.pagination(.pageLimitReached)) { try await collect() }
        } else {
            let items = try await collect()
            #expect(items == Array(0..<(ending == "empty-page" ? limit - 1 : limit)))
        }
        #expect(offsets.values == Array((prefetched ? 1 : 0)..<limit))
    }

    @Test
    func unavailableEntriesStillAdvanceToTheNextPage() async throws {
        let offsets = OffsetRecorder()
        let items = try await Pagination.collect { offset in
            offsets.record(offset)
            return Pagination.Page(
                items: offset == 0 ? [] : ["last"], pageEntryCount: offset == 0 ? 2 : 1, totalCount: 3)
        }
        #expect(items == ["last"])
        #expect(offsets.values == [0, 2])
    }

    @Test(arguments: [nil, 0] as [Int?])
    func emptyFirstPageCompletesWithoutAFollowingRequest(total: Int?) async throws {
        let calls = OffsetRecorder()
        let items = try await Pagination.collect { offset in
            calls.record(offset)
            return Pagination.Page(items: [Int](), pageEntryCount: 0, totalCount: total)
        }
        #expect(items.isEmpty)
        #expect(calls.values == [0])
    }

    @Test
    func checkedOffsetOverflowFailsWithoutAllocatingReportedEntries() async {
        let calls = OffsetRecorder()
        await #expect(throws: PartnerAPIError.pagination(.incompleteCollection)) {
            _ = try await Pagination.collect(
                firstPage: Pagination.Page(items: [Int](), pageEntryCount: Int.max, totalCount: nil)
            ) { offset in
                calls.record(offset)
                return Pagination.Page(items: [], pageEntryCount: 1, totalCount: nil)
            }
        }
        #expect(calls.values == [Int.max])
    }

    @Test
    func fetchFailurePropagatesWithoutReturningPartialItems() async {
        let calls = OffsetRecorder()
        await #expect(throws: WalkProbe.boom) {
            _ = try await Pagination.collect { offset in
                calls.record(offset)
                guard offset == 0 else { throw WalkProbe.boom }
                return Pagination.Page(items: [offset], pageEntryCount: 1, totalCount: 10)
            }
        }
        #expect(calls.values == [0, 1])
    }

    @Test(arguments: [false, true])
    @MainActor
    func cancelledAdmissionCannotConsumeOrFetchPages(prefetched: Bool) async {
        let calls = OffsetRecorder()
        let first = Pagination.Page(items: [0], pageEntryCount: 1, totalCount: 1)
        let pending = Task {
            try await Pagination.collect(firstPage: prefetched ? first : nil) { offset in
                calls.record(offset)
                return first
            }
        }
        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(calls.values.isEmpty)
    }

    @Test
    func cancelledWalkCannotSucceedWhenAnUncooperativeTerminalPageArrives() async throws {
        let responses = HarnessResponseGate<Pagination.Page<Int>>(cancellation: .ignored)
        let calls = OffsetRecorder()
        let pending = Task {
            try await Pagination.collect { offset in
                calls.record(offset)
                if offset == 0 { return Pagination.Page(items: [0], pageEntryCount: 1, totalCount: nil) }
                return try await responses.wait()
            }
        }
        defer { pending.cancel(); responses.close() }
        try await requireEventually { responses.waiterCount == 1 }
        pending.cancel()
        responses.finish(Pagination.Page(items: [], pageEntryCount: 0, totalCount: nil))
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(calls.values == [0, 1])
    }

    @Test
    @MainActor
    func cancelledCompleteCollectionCannotFetchItsHeader() async {
        let calls = OffsetRecorder()
        let pending = Task {
            try await CompleteCatalogCollection<String, Int>.collect { offset in
                calls.record(offset)
                return try ValidatedCatalogPage(
                    header: "header", typename: "Album", expectedType: "Album", uri: nil,
                    requestedURI: "spotify:album:fixture", items: [], totalCount: 0)
            }
        }
        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(calls.values.isEmpty)
    }
}
