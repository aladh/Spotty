import Testing
import SpottyDomain
import Foundation

private enum WalkProbe: Error, Equatable {
    case boom
}

@Suite("Pagination Collect")
struct PaginationCollectTests {
    @Test(arguments: [[nil, 3, 4], [nil, 3, 2], [3, 4], [3, 2], [nil, nil, 1], [-1], [nil, -1], [0]] as [[Int?]])
    func contradictoryTotalsCannotPublishACompleteCollection(totals: [Int?]) async {
        await #expect(throws: Pagination.Failure.incompleteCollection) {
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
        await #expect(throws: Pagination.Failure.incompleteCollection) {
            _ = try await Pagination.collect { offset in
                Pagination.Page(
                    items: [offset, offset + 1], pageEntryCount: 2, totalCount: offset == 0 ? firstTotal : 3)
            }
        }
    }

    @Test(arguments: [-1, 0, 1])
    func rawEntryCountsCannotBeSmallerThanDecodedItems(count: Int) async {
        await #expect(throws: Pagination.Failure.incompleteCollection) {
            _ = try await Pagination.collect { _ in
                Pagination.Page(items: [0, 1], pageEntryCount: count, totalCount: 1)
            }
        }
    }

    @Test
    func testPaginationCollect() async {
        do {
            let ordinary = OffsetRecorder()
            await expectCollect(
                "ordinary totalCount concatenates pages in order",
                expected: [0, 1, 2]
            ) { offset in
                ordinary.record(offset)
                if offset == 0 {
                    return Pagination.Page(items: [0, 1], pageEntryCount: 2, totalCount: 3)
                }
                return Pagination.Page(items: [2], pageEntryCount: 1, totalCount: 3)
            }
            #expect((ordinary.values) == ([0, 2]), "ordinary totalCount fetches each named offset once")

            let boundary = OffsetRecorder()
            await expectCollect(
                "exact page-boundary totalCount does not fetch past the last page",
                expected: [0, 1, 2, 3]
            ) { offset in
                boundary.record(offset)
                return Pagination.Page(
                    items: [offset, offset + 1],
                    pageEntryCount: 2,
                    totalCount: 4
                )
            }
            #expect((boundary.values) == ([0, 2]), "exact page-boundary fetches two pages")

            await expectCollect(
                "omitted totalCount ends on a final empty page",
                expected: [0, 1]
            ) { offset in
                if offset == 0 {
                    return Pagination.Page(items: [0, 1], pageEntryCount: 2, totalCount: nil)
                }
                return Pagination.Page(items: [], pageEntryCount: 0, totalCount: nil)
            }

            await expectCollect(
                "empty first page yields no items",
                expected: []
            ) { _ in
                Pagination.Page(items: [Int](), pageEntryCount: 0, totalCount: 0)
            }

            let zeroCap = OffsetRecorder()
            await expectThrown(
                "a zero page cap fails before any fetch",
                Pagination.Failure.pageLimitReached
            ) {
                _ = try await Pagination.collect(maximumPageCount: 0) { offset in
                    zeroCap.record(offset)
                    return Pagination.Page(items: [offset], pageEntryCount: 0, totalCount: 0)
                }
            }
            #expect((zeroCap.values) == ([]), "a zero page cap does not fetch")

            let capOffsets = OffsetRecorder()
            await expectThrown(
                "cap exhaustion fails instead of returning a partial list",
                Pagination.Failure.pageLimitReached
            ) {
                _ = try await Pagination.collect(maximumPageCount: 2) { offset in
                    capOffsets.record(offset)
                    return Pagination.Page(items: [offset], pageEntryCount: 1, totalCount: nil)
                }
            }
            #expect((capOffsets.values) == ([0, 1]), "cap exhaustion fetches exactly the allowed pages")

            let stalled = OffsetRecorder()
            await expectThrown(
                "a non-progressing offset fails rather than looping",
                Pagination.Failure.offsetDidNotAdvance
            ) {
                _ = try await Pagination.collect(
                    maximumPageCount: 4,
                    nextOffset: { offset, _, _ in offset }
                ) { offset in
                    stalled.record(offset)
                    return Pagination.Page(items: [offset], pageEntryCount: 1, totalCount: nil)
                }
            }
            #expect((stalled.values) == ([0]), "a non-progressing response is fetched once")

            let thrown = OffsetRecorder()
            await expectThrown(
                "fetch errors propagate without a partial success",
                WalkProbe.boom
            ) {
                _ = try await Pagination.collect { offset in
                    thrown.record(offset)
                    if offset > 0 { throw WalkProbe.boom }
                    return Pagination.Page(items: [offset], pageEntryCount: 1, totalCount: 10)
                }
            }
            #expect((thrown.values) == ([0, 1]), "a mid-walk error stops after the failing page")

            let parked = ReleaseGate()
            let fetches = OffsetRecorder()
            let pending = Task {
                try await Pagination.collect { offset in
                    fetches.record(offset)
                    if offset > 0 {
                        await parked.park()
                        return Pagination.Page(items: [Int](), pageEntryCount: 0, totalCount: nil)
                    }
                    return Pagination.Page(items: [offset], pageEntryCount: 1, totalCount: nil)
                }
            }
            await parked.waitUntilEntered()
            pending.cancel()
            parked.open()
            var cancelled = false
            do {
                _ = try await pending.value
            } catch is CancellationError {
                cancelled = true
            } catch {
                #expect((false) == true, "cancellation stays CancellationError, got \(error)")
            }
            #expect((cancelled) == true, "a cancelled walk does not succeed after a terminal page returns")
            #expect((fetches.values) == ([0, 1]), "cancellation does not fetch past the parked page")
        }
    }
}

private func expectCollect(
    _ label: String,
    expected: [Int],
    fetchPage: @escaping @Sendable (Int) async throws -> Pagination.Page<Int>
) async {
    do {
        let items = try await Pagination.collect(maximumPageCount: 8, fetchPage: fetchPage)
        #expect((items) == (expected), "\(label)")
    } catch {
        #expect((false) == true, "\(label) succeeds, got \(error)")
    }
}

private func expectThrown<Failure: Error & Equatable>(
    _ label: String,
    _ expected: Failure,
    perform: @escaping () async throws -> Void
) async {
    do {
        try await perform()
        #expect((false) == true, "\(label) throws")
    } catch let error as Failure {
        #expect((error) == (expected), "\(label)")
    } catch {
        #expect((false) == true, "\(label) throws \(Failure.self), got \(error)")
    }
}

private final class OffsetRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int] = []

    var values: [Int] {
        lock.withLock { recorded }
    }

    func record(_ offset: Int) {
        lock.lock()
        recorded.append(offset)
        lock.unlock()
    }
}

private final class ReleaseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered: CheckedContinuation<Void, Never>?
    private var parked: CheckedContinuation<Void, Never>?
    private var hasEntered = false
    private var released = false

    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if hasEntered {
                lock.unlock()
                continuation.resume()
            } else {
                entered = continuation
                lock.unlock()
            }
        }
    }

    func park() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            hasEntered = true
            let enteredWaiter = entered
            entered = nil
            if released {
                lock.unlock()
                enteredWaiter?.resume()
                continuation.resume()
            } else {
                parked = continuation
                lock.unlock()
                enteredWaiter?.resume()
            }
        }
    }

    func open() {
        lock.lock()
        released = true
        let parked = parked
        self.parked = nil
        lock.unlock()
        parked?.resume()
    }
}
