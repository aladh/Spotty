import Darwin
import Foundation
import SpottyCatalogStorage
import SpottyDomain
import SpottyRuntimeContracts
import SpottyTestSupport
import Testing
@testable import SpottySessionRuntime

struct CatalogEntityQueryChecks {
    @Test @MainActor func disposingProviderFinishesRetainedSubscriptionReaders() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-disposal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        var provider: PersistentCatalogProvider? = PersistentCatalogProvider(
            source: EntityQuerySource(), rootDirectory: directory)
        await provider?.activate(accountEpoch: 1)
        _ = try await provider?.profile()
        let subscription = try await provider!.subscribeCatalogEntities([])
        var started = false
        var finished = false
        let reader = Task { @MainActor in
            for await _ in subscription.updates { started = true }
            finished = true
        }
        defer { reader.cancel() }
        try await requireEventually { started }
        weak let released = provider
        provider = nil
        try await requireEventually { released == nil }
        try await requireEventually(description: "disposed catalog provider finishes retained subscription readers") {
            finished
        }
        await reader.value
    }

    @Test func retirementFencesAnAdmittedCompleteCacheRead() async throws {
        let fixture = QueryFixture()
        defer { fixture.removeFiles() }
        await fixture.source.setTracks((0..<501).map { queryTrack("retiring-\($0)") })
        try await fixture.bind()
        _ = try await fixture.provider.playlist(id: "measurement")
        _ = try await restoreAndRetire(fixture.provider)
    }

    @Test(arguments: EntityReadInterruption.allCases)
    func interruptedEntityReadCannotReturnPartialMetadata(interruption: EntityReadInterruption) async throws {
        let fixture = QueryFixture()
        defer { fixture.removeFiles() }
        let rows = (0..<501).map { queryTrack("interrupted-\($0)") }
        await fixture.source.setTracks(rows)
        try await fixture.bind()
        _ = try await fixture.provider.playlist(id: "measurement")
        let subscription = try await fixture.provider.subscribeCatalogEntities(Set(rows.map(\.uri)))
        let change = CatalogEntityChange(token: subscription.token, revision: 0)
        try await interruptEntityRead(fixture.provider, change: change, interruption: interruption)
        #expect(await fixture.provider.retire(accountEpoch: 1, purge: true))
    }

    @Test(arguments: [0, 500, 501, 20_000])
    func completeEntitiesIncludeAllBatchesAndSkipMissingRows(requestCount: Int) async throws {
        let fixture = QueryFixture()
        defer { fixture.removeFiles() }
        let rows = (0..<min(requestCount, 502)).map { queryTrack("\($0)") }
        await fixture.source.setTracks(rows)
        try await fixture.bind()
        _ = try await fixture.provider.playlist(id: "one")
        let requested = Set((0..<requestCount).map { queryTrack("\($0)").uri })
        let subscription = try await fixture.provider.subscribeCatalogEntities(requested)
        var updates = subscription.updates.makeAsyncIterator()
        let initial = try #require(await updates.next())
        let entities = try await fixture.provider.catalogEntities(for: initial)
        #expect(entities.count == rows.count)
        #expect(Set(entities.keys) == Set(rows.map(\.uri)))
        #expect(entities.allSatisfy { $0.key == $0.value.uri })
        await fixture.provider.acknowledgeCatalogEntities(subscription.token, revision: initial.revision)
        #expect(await fixture.provider.retire(accountEpoch: 1, purge: true))
        #expect(await updates.next() == nil)
    }

    @Test func freshAccountProofRetriesATransientCatalogOpenFailure() async throws {
        let fixture = QueryFixture()
        defer { fixture.removeFiles() }
        let retained = queryTrack("retained")
        let blocker = PersistentCatalog(rootDirectory: fixture.directory, accountID: "spotify:user:query-account")
        _ = try await blocker.replaceCollection(
            CatalogCollectionWrite(
                key: "spotify:playlist:retained", occurrences: CatalogOccurrence.browsingRows([retained]),
                completeness: .complete, fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            scope: blocker.scope)
        // A real owner lock makes the first open fail without replacing the account owner or
        // treating the verified profile as an unavailable live gateway response.
        try await fixture.bind()
        await #expect(throws: CatalogEntityQueryFailure.unavailable) {
            try await fixture.provider.subscribeCatalogEntities([retained.uri])
        }
        try await blocker.close(scope: blocker.scope)
        _ = try await fixture.provider.profile()
        let subscription = try await fixture.provider.subscribeCatalogEntities([retained.uri])
        let entities = try await fixture.provider.catalogEntities(
            for: CatalogEntityChange(token: subscription.token, revision: 0))
        #expect(entities[retained.uri]?.title == retained.title)
        #expect(await fixture.provider.retire(accountEpoch: 1, purge: true))
    }

    @Test func retryingAccountProofCannotRecoverQueriesAfterAMissedLiveWrite() async throws {
        let fixture = QueryFixture()
        defer { fixture.removeFiles() }
        let retained = queryTrack("one", title: "Retained")
        let blocker = PersistentCatalog(rootDirectory: fixture.directory, accountID: "spotify:user:query-account")
        _ = try await blocker.replaceCollection(
            CatalogCollectionWrite(
                key: "spotify:playlist:retained", occurrences: CatalogOccurrence.browsingRows([retained]),
                completeness: .complete, fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            scope: blocker.scope)
        try await fixture.bind()
        let fresh = queryTrack("one", title: "Fresh but not retained")
        await fixture.source.setTracks([fresh])
        #expect(try await fixture.provider.playlist(id: "one").tracks == [fresh])
        try await blocker.close(scope: blocker.scope)
        _ = try await fixture.provider.profile()
        // A later unrelated success can reopen storage, but cannot repair the missed entity.
        await fixture.source.setTracks([queryTrack("unrelated")])
        _ = try await fixture.provider.album(id: "unrelated")
        _ = try await fixture.provider.profile()
        await #expect(throws: CatalogEntityQueryFailure.unavailable) {
            try await fixture.provider.subscribeCatalogEntities([fresh.uri])
        }
        #expect(await fixture.provider.retire(accountEpoch: 1, purge: true))
    }

    @Test func relinkedMetadataRetainsRequestedQueryIdentity() async throws {
        let fixture = QueryFixture()
        defer { fixture.removeFiles() }
        let requested = "spotify:track:requested"
        let playable = queryTrack("playable", occurrence: "server-occurrence")
        let storage = PersistentCatalog(rootDirectory: fixture.directory, accountID: "spotify:user:query-account")
        _ = try await storage.replaceCollection(
            CatalogCollectionWrite(
                key: "spotify:playlist:relinked",
                occurrences: [
                    .init(id: "display", requestedURI: requested, serverUID: "server-occurrence", track: playable)
                ],
                completeness: .complete, fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
            ), scope: storage.scope
        )
        try await storage.close(scope: storage.scope)
        try await fixture.bind()
        let subscription = try await fixture.provider.subscribeCatalogEntities([requested])
        let entities = try await fixture.provider.catalogEntities(
            for: CatalogEntityChange(token: subscription.token, revision: 0))
        let entity = try #require(entities[requested])
        #expect(entity.uri == requested)
        #expect(entity.title == playable.title)
        #expect(entity == CatalogTrackMetadata(track: playable, requestedURI: requested))
        #expect(await fixture.provider.retire(accountEpoch: 1, purge: true))
    }

    @Test func effectiveMetadataChangesAreFilteredAndCoalesceUntilAcknowledged() async throws {
        let fixture = QueryFixture()
        defer { fixture.removeFiles() }
        let first = queryTrack("one")
        let second = queryTrack("two")
        await fixture.source.setTracks([first, second])
        try await fixture.bind()
        _ = try await fixture.provider.playlist(id: "one")
        let subscription = try await fixture.provider.subscribeCatalogEntities([first.uri, second.uri])
        var updates = subscription.updates.makeAsyncIterator()
        let initial = try #require(await updates.next())
        await fixture.provider.acknowledgeCatalogEntities(subscription.token, revision: initial.revision)

        // Neither a different collection nor an identical effective entity can advance revision.
        await fixture.source.setTracks([queryTrack("unrelated")])
        _ = try await fixture.provider.album(id: "unrelated")
        await fixture.source.setTracks([queryTrack("one", occurrence: "new-occurrence")])
        _ = try await fixture.provider.album(id: "identical")
        let silent = try await fixture.provider.catalogEntities(for: initial)
        #expect(silent.count == 0)

        await fixture.source.setTracks([queryTrack("one", title: "Updated one")])
        _ = try await fixture.provider.album(id: "changed-one")
        let updateOne = try #require(await updates.next())
        #expect(updateOne.revision == initial.revision + 1)
        let firstUpdate = try await fixture.provider.catalogEntities(for: updateOne)
        #expect(firstUpdate.count == 1)
        #expect(firstUpdate[first.uri]?.title == "Updated one")
        await fixture.source.setTracks([queryTrack("two", title: "Updated two")])
        _ = try await fixture.provider.album(id: "changed-two")
        await fixture.provider.acknowledgeCatalogEntities(subscription.token, revision: updateOne.revision)
        let updateBoth = try #require(await updates.next())
        #expect(updateBoth.revision == updateOne.revision + 1)
        await #expect(throws: CatalogEntityQueryFailure.superseded) {
            try await fixture.provider.catalogEntities(
                for: CatalogEntityChange(token: subscription.token, revision: updateOne.revision))
        }
        let entities = try await fixture.provider.catalogEntities(for: updateBoth)
        #expect(entities.count == 2)
        #expect(entities[first.uri]?.title == "Updated one")
        #expect(entities[second.uri]?.title == "Updated two")
        await fixture.provider.acknowledgeCatalogEntities(subscription.token, revision: updateBoth.revision)
        let acknowledged = try await fixture.provider.catalogEntities(for: updateBoth)
        #expect(acknowledged.count == 0)
        #expect(await fixture.provider.retire(accountEpoch: 1, purge: true))
    }

    @Test func slowSubscriberReceivesTheUnionWithoutAnUnboundedEventQueue() async throws {
        let fixture = QueryFixture()
        defer { fixture.removeFiles() }
        try await fixture.bind()
        let subscription = try await fixture.provider.subscribeCatalogEntities([
            queryTrack("one").uri, queryTrack("two").uri,
        ])
        await fixture.source.setTracks([queryTrack("one")])
        _ = try await fixture.provider.playlist(id: "one")
        await fixture.source.setTracks([queryTrack("two")])
        _ = try await fixture.provider.album(id: "two")
        var updates = subscription.updates.makeAsyncIterator()
        let newest = try #require(await updates.next())
        #expect(newest.revision == 2)
        let entities = try await fixture.provider.catalogEntities(for: newest)
        #expect(entities.count == 2)
        await fixture.provider.unsubscribeCatalogEntities(subscription.token)
        #expect(await updates.next() == nil)
        #expect(await fixture.provider.retire(accountEpoch: 1, purge: true))
    }

    @Test func subscriptionsAreBoundedAndOldTokensCannotRemoveReplacementObservations() async throws {
        let fixture = QueryFixture()
        defer { fixture.removeFiles() }
        await fixture.provider.activate(accountEpoch: 1)
        await #expect(throws: CatalogEntityQueryFailure.unavailable) {
            try await fixture.provider.subscribeCatalogEntities([])
        }
        _ = try await fixture.provider.profile()
        await #expect(throws: CatalogEntityQueryFailure.invalidRequest) {
            try await fixture.provider.subscribeCatalogEntities(
                Set((0...CatalogEntityQueryLimits.maximumRequestedURIs).map(String.init)))
        }
        var subscriptions: [CatalogEntitySubscription] = []
        for _ in 0..<CatalogEntityQueryLimits.maximumSubscriptions {
            subscriptions.append(try await fixture.provider.subscribeCatalogEntities([]))
        }
        await #expect(throws: CatalogEntityQueryFailure.capacity) {
            try await fixture.provider.subscribeCatalogEntities([])
        }
        let old = try #require(subscriptions.first)
        #expect(await fixture.provider.retire(accountEpoch: 1, purge: false))
        await fixture.provider.activate(accountEpoch: 2)
        _ = try await fixture.provider.profile()
        let replacement = try await fixture.provider.subscribeCatalogEntities([])
        #expect(replacement.token.accountLifetime != old.token.accountLifetime)
        await fixture.provider.unsubscribeCatalogEntities(old.token)
        await fixture.provider.acknowledgeCatalogEntities(old.token, revision: 0)
        await #expect(throws: CatalogEntityQueryFailure.retired) {
            try await fixture.provider.catalogEntities(for: CatalogEntityChange(token: old.token, revision: 0))
        }
        #expect(
            try await fixture.provider.catalogEntities(for: CatalogEntityChange(token: replacement.token, revision: 0))
                .isEmpty)
        #expect(await fixture.provider.retire(accountEpoch: 2, purge: true))
    }

    @Test func failedPersistenceCannotHydrateFreshLiveRowsFromOlderEntities() async throws {
        let fixture = QueryFixture()
        defer { fixture.removeFiles() }
        await fixture.source.setTracks([queryTrack("one", title: "Old")])
        try await fixture.bind()
        _ = try await fixture.provider.playlist(id: "one")
        let observation = try await fixture.provider.subscribeCatalogEntities([queryTrack("one").uri])
        var updates = observation.updates.makeAsyncIterator()
        _ = await updates.next()
        // This valid live response exceeds the cache's bounded record size; retention rejects it.
        let fresh = queryTrack("one", title: String(repeating: "N", count: 70_000))
        await fixture.source.setTracks([fresh])
        #expect(try await fixture.provider.playlist(id: "one").tracks == [fresh])
        #expect(await updates.next() == nil)
        await #expect(throws: CatalogEntityQueryFailure.unavailable) {
            try await fixture.provider.subscribeCatalogEntities([fresh.uri])
        }
        await fixture.source.setTracks([queryTrack("unrelated")])
        _ = try await fixture.provider.album(id: "unrelated")
        await #expect(throws: CatalogEntityQueryFailure.unavailable) {
            try await fixture.provider.subscribeCatalogEntities([fresh.uri])
        }
        #expect(await fixture.provider.retire(accountEpoch: 1, purge: true))
    }

    @Test func rejectedRefreshCannotHydrateFreshLiveRowsFromAnOlderClockSample() async throws {
        let fixture = QueryFixture()
        defer { fixture.removeFiles() }
        let row = queryTrack("one", title: "Retained before clock reset")
        let storage = PersistentCatalog(rootDirectory: fixture.directory, accountID: "spotify:user:query-account")
        _ = try await storage.replaceCollection(
            CatalogCollectionWrite(
                key: "spotify:playlist:one", occurrences: CatalogOccurrence.browsingRows([row]),
                completeness: .complete, fetchedAt: Date(timeIntervalSince1970: 4_000_000_000)
            ), scope: storage.scope
        )
        try await storage.close(scope: storage.scope)
        try await fixture.bind()
        let fresh = queryTrack("one", title: "Fresh after clock reset")
        await fixture.source.setTracks([fresh])
        #expect(try await fixture.provider.playlist(id: "one").tracks == [fresh])
        await #expect(throws: CatalogEntityQueryFailure.unavailable) {
            try await fixture.provider.subscribeCatalogEntities([fresh.uri])
        }
        #expect(await fixture.provider.retire(accountEpoch: 1, purge: true))
    }

    @Test func changedAccountProofFinishesOutstandingObservations() async throws {
        let fixture = QueryFixture()
        defer { fixture.removeFiles() }
        try await fixture.bind()
        let subscription = try await fixture.provider.subscribeCatalogEntities([])
        var updates = subscription.updates.makeAsyncIterator()
        _ = await updates.next()
        await fixture.source.setAccount("spotify:user:replacement")
        await #expect(throws: CatalogReadFailure.sessionExpired) { try await fixture.provider.profile() }
        #expect(await updates.next() == nil)
        #expect(await fixture.provider.retire(accountEpoch: 1, purge: true))
    }
}

enum EntityReadInterruption: CaseIterable, Sendable {
    case cancelledBeforeAdmission, cancelledDuringRead, unsubscribed, retired
}

/// Admission runs synchronously on the provider through the first storage await. Interrupt on
/// that same actor before the read can resume; no timing or oversized fixture establishes order.
private func interruptEntityRead(
    _ provider: isolated PersistentCatalogProvider, change: CatalogEntityChange, interruption: EntityReadInterruption
) async throws {
    let read = Task.immediate {
        if interruption == .cancelledBeforeAdmission { withUnsafeCurrentTask { $0?.cancel() } }
        return try await provider.catalogEntities(for: change)
    }
    defer { read.cancel() }
    switch interruption {
    case .cancelledBeforeAdmission, .cancelledDuringRead:
        read.cancel()
        await #expect(throws: CancellationError.self) { _ = try await read.value }
        let retry = try await provider.catalogEntities(for: change)
        #expect(retry.count == 501, "cancellation must not acknowledge the pending metadata")
    case .unsubscribed:
        await provider.unsubscribeCatalogEntities(change.token)
        await #expect(throws: CatalogEntityQueryFailure.retired) { _ = try await read.value }
    case .retired:
        #expect(await provider.retire(accountEpoch: 1, purge: true))
        await #expect(throws: CatalogReadFailure.sessionExpired) { _ = try await read.value }
    }
}

/// Opt-in complete entity-read cost, including storage batches, with no timing assertion.
struct CatalogEntityQueryMeasurementTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPOTTY_ENTITY_PAGING_REPORT"] != nil))
    func measureCompleteEntityRead() async throws {
        let fixture = QueryFixture()
        defer { fixture.removeFiles() }
        let environment = ProcessInfo.processInfo.environment
        let requestedCount = try #require(Int(environment["SPOTTY_ENTITY_PAGING_REQUEST_COUNT"] ?? "20000"))
        let iterations = try #require(Int(environment["SPOTTY_ENTITY_PAGING_ITERATIONS"] ?? "5"))
        try #require((1...CatalogEntityQueryLimits.maximumRequestedURIs).contains(requestedCount))
        try #require((1...10_000).contains(iterations))
        let rows = (0..<max(1, requestedCount / 2)).map { queryTrack("synthetic-\($0)") }
        await fixture.source.setTracks(rows)
        try await fixture.bind()
        _ = try await fixture.provider.playlist(id: "measurement")
        let uris = Set((0..<requestedCount).map { "spotify:track:synthetic-\($0)" })
        var reports: [[String: Any]] = []
        for iteration in 0..<iterations {
            let started = ContinuousClock.now
            let before = try cpuSeconds()
            let subscription = try await fixture.provider.subscribeCatalogEntities(uris)
            let entities = try await fixture.provider.catalogEntities(
                for: CatalogEntityChange(token: subscription.token, revision: 0))
            let found = Set(entities.keys)
            await fixture.provider.unsubscribeCatalogEntities(subscription.token)
            let cpu = try cpuSeconds() - before
            let elapsed = started.duration(to: .now).components
            reports.append([
                "iteration": iteration, "cpuSeconds": cpu,
                "wallSeconds": Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
            ])
            #expect(found == Set(rows.map(\.uri)))
        }
        #expect(await fixture.provider.retire(accountEpoch: 1, purge: true))
        let report = try JSONSerialization.data(
            withJSONObject: [
                "version": 1, "requestedCount": requestedCount, "retainedCount": rows.count,
                "storageBatchSize": CatalogRetentionLimits().pageSize, "iterations": iterations,
                "os": ProcessInfo.processInfo.operatingSystemVersionString, "measurements": reports,
            ], options: [.prettyPrinted, .sortedKeys])
        let path = try #require(ProcessInfo.processInfo.environment["SPOTTY_ENTITY_PAGING_REPORT"])
        try report.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPOTTY_COLLECTION_RESTORE_REPORT"] != nil))
    func measureCachedCollectionRestore() async throws {
        let environment = ProcessInfo.processInfo.environment
        let iterations = try #require(Int(environment["SPOTTY_COLLECTION_RESTORE_ITERATIONS"] ?? "10"))
        try #require((1...1_000).contains(iterations))
        var reports: [[String: Any]] = []
        var retirements: [[String: Any]] = []
        for count in [500, 5_000, 10_000] {
            let fixture = QueryFixture()
            defer { fixture.removeFiles() }
            let rows = (0..<count).map { queryTrack("restore-\($0)") }
            await fixture.source.setTracks(rows)
            try await fixture.bind()
            _ = try await fixture.provider.playlist(id: "measurement")
            try #require(try await fixture.provider.cachedPlaylist(id: "measurement")?.tracks.count == count)
            for iteration in 0..<iterations {
                let started = ContinuousClock.now
                let before = try cpuSeconds()
                let snapshot = try await fixture.provider.cachedPlaylist(id: "measurement")
                let cpu = try cpuSeconds() - before
                let elapsed = started.duration(to: .now).components
                try #require(snapshot?.tracks.count == count)
                #expect(snapshot?.tracks.map(\.uri) == rows.map(\.uri))
                reports.append([
                    "rows": count, "iteration": iteration, "cpuSeconds": cpu,
                    "wallSeconds": Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
                ])
            }
            let elapsed = try await restoreAndRetire(fixture.provider)
            retirements.append(["rows": count, "wallSeconds": elapsed])
        }
        var usage = rusage()
        try #require(getrusage(RUSAGE_SELF, &usage) == 0)
        let report = try JSONSerialization.data(
            withJSONObject: [
                "version": 1, "iterations": iterations, "measurements": reports, "retirements": retirements,
                "processPeakResidentBytes": usage.ru_maxrss,
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
            ], options: [.prettyPrinted, .sortedKeys])
        let path = try #require(environment["SPOTTY_COLLECTION_RESTORE_REPORT"])
        try report.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// End-to-end provider/SQLite publication cost for slow subscribers, without timing assertions.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPOTTY_ENTITY_FANOUT_REPORT"] != nil))
    func measureSlowSubscriberInvalidations() async throws {
        let fixture = QueryFixture()
        defer { fixture.removeFiles() }
        try await fixture.bind()
        var reports: [[String: Any]] = []
        let writes = 100
        let iterations = 3
        for requestedCount in [1, CatalogEntityQueryLimits.maximumRequestedURIs] {
            let requested = Set((0..<requestedCount).map { "spotify:track:fanout-\($0)" })
            for subscriberCount in [1, CatalogEntityQueryLimits.maximumSubscriptions] {
                for iteration in 0..<iterations {
                    var subscriptions: [CatalogEntitySubscription] = []
                    for _ in 0..<subscriberCount {
                        subscriptions.append(try await fixture.provider.subscribeCatalogEntities(requested))
                    }
                    for subscription in subscriptions {
                        await fixture.provider.acknowledgeCatalogEntities(subscription.token, revision: 0)
                    }
                    let prefixCount = max(1, requestedCount / 2)
                    await fixture.source.setTracks(
                        (0..<prefixCount).map {
                            queryTrack("fanout-\($0)", title: "Seed \(requestedCount) \(subscriberCount) \(iteration)")
                        })
                    _ = try await fixture.provider.album(id: "fanout-seed")
                    for warmup in 0..<5 {
                        let index = requestedCount == 1 ? 0 : prefixCount + warmup
                        await fixture.source.setTracks([
                            queryTrack("fanout-\(index)", title: "Warmup \(iteration) \(warmup)")
                        ])
                        _ = try await fixture.provider.album(id: "fanout")
                    }
                    let started = ContinuousClock.now
                    let before = try cpuSeconds()
                    for write in 0..<writes {
                        let index = requestedCount == 1 ? 0 : prefixCount + 5 + write
                        await fixture.source.setTracks([
                            queryTrack("fanout-\(index)", title: "Update \(iteration) \(write)")
                        ])
                        _ = try await fixture.provider.album(id: "fanout")
                    }
                    let cpu = try cpuSeconds() - before
                    let elapsed = started.duration(to: .now).components
                    reports.append([
                        "requestedCount": requestedCount, "subscribers": subscriberCount,
                        "iteration": iteration, "writes": writes, "cpuSeconds": cpu,
                        "wallSeconds": Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
                    ])
                    for subscription in subscriptions {
                        var updates = subscription.updates.makeAsyncIterator()
                        let latest = try #require(await updates.next())
                        #expect(latest.revision == UInt64(writes + 6))
                        let entities = try await fixture.provider.catalogEntities(for: latest)
                        #expect(entities.count == (requestedCount == 1 ? 1 : prefixCount + 5 + writes))
                        let lastIndex = requestedCount == 1 ? 0 : prefixCount + 5 + writes - 1
                        #expect(entities["spotify:track:fanout-\(lastIndex)"]?.title == "Update \(iteration) 99")
                        await fixture.provider.unsubscribeCatalogEntities(subscription.token)
                    }
                }
            }
        }
        #expect(await fixture.provider.retire(accountEpoch: 1, purge: true))
        let path = try #require(ProcessInfo.processInfo.environment["SPOTTY_ENTITY_FANOUT_REPORT"])
        let report = try JSONSerialization.data(
            withJSONObject: ["version": 1, "measurements": reports], options: [.prettyPrinted, .sortedKeys])
        try report.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func cpuSeconds() throws -> Double {
        var usage = rusage()
        try #require(getrusage(RUSAGE_SELF, &usage) == 0)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
}

/// Immediate admission reaches the storage await while retaining this actor turn. Retirement
/// therefore revokes publication before the suspended read can resume on the provider.
private func restoreAndRetire(_ provider: isolated PersistentCatalogProvider) async throws -> Double {
    let read = Task.immediate { try await provider.cachedPlaylist(id: "measurement") }
    defer { read.cancel() }
    let started = ContinuousClock.now
    #expect(await provider.retire(accountEpoch: 1, purge: true))
    let elapsed = started.duration(to: .now).components
    await #expect(throws: CatalogReadFailure.sessionExpired) { try await read.value }
    return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
}

private struct QueryFixture {
    let directory: URL
    let source: EntityQuerySource
    let provider: PersistentCatalogProvider

    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-query-\(UUID())")
        source = EntityQuerySource()
        provider = PersistentCatalogProvider(source: source, rootDirectory: directory)
    }

    func bind() async throws {
        await provider.activate(accountEpoch: 1)
        _ = try await provider.profile()
    }

    func removeFiles() { try? FileManager.default.removeItem(at: directory) }
}

private actor EntityQuerySource: CatalogProviding {
    private var tracks: [CatalogTrack] = []
    private var account = "spotify:user:query-account"
    func setTracks(_ values: [CatalogTrack]) { tracks = values }
    func setAccount(_ value: String) { account = value }
    func profile() -> CatalogProfileSnapshot { .init(name: "Query account", uri: account) }
    func playlist(id _: String) -> CatalogPlaylistSnapshot { .init(description: "", ownerURI: nil, tracks: tracks) }
    func album(id _: String) -> CatalogAlbumSnapshot { .init(tracks: tracks, releaseDate: "") }
    func searchTracks(_: String, limit _: Int) -> [CatalogTrack] { [] }
    func home() -> CatalogHomeSnapshot { .init(greeting: "", sections: []) }
    func playlistLibrary() -> [PlaylistLibraryNode] { [] }
    func libraryAlbums() -> [CatalogItem] { [] }
    func libraryArtists() -> [CatalogItem] { [] }
    func libraryTracks() -> [CatalogTrack] { [] }
}

private func queryTrack(_ id: String, title: String? = nil, occurrence: String? = nil) -> CatalogTrack {
    CatalogTrack(
        id: occurrence ?? id, uri: "spotify:track:\(id)", title: title ?? id,
        artist: "Artist", album: "Album", duration: 100, artworkURL: nil, addedAt: nil,
        occurrenceUID: occurrence
    )
}
