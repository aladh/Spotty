import CoreGraphics
import Foundation
import ImageIO
import SpottyRuntimeContracts
import SpottyTestSupport
import Synchronization
import Testing
@testable import SpottySessionRuntime

@Suite("Account artwork pipeline")
struct ArtworkPipelineTests {
    @Test func sameAccountSameSizeReplacementKeepsItsOwnSourceAndThumbnail() async throws {
        let loader = ArtworkFixtureLoader(data: try artworkFixture(width: 16, height: 16), suspended: true)
        try await withArtworkFixture(loader: loader) { fixture in
            let pipeline = ArtworkPipeline(loader: loader, maximumActiveRequests: 1)
            await fixture.observe(pipeline)
            await pipeline.activate(accountEpoch: 1)
            let first = await startArtwork(pipeline, fixture: fixture, name: "replaced")
            try await requireEventually { loader.parkedLoadCount == 1 }
            first.cancel()
            try await first.requireCompletion()
            await #expect(throws: CancellationError.self) { try await first.value }
            let replacement = await startArtwork(pipeline, fixture: fixture, name: "replaced")
            #expect(await pipeline.statistics().pendingRequests == 1)
            let releasedOld = loader.releaseOne(with: try artworkFixture(width: 16, height: 16))
            #expect(releasedOld)
            // Capacity one makes the old source settle before the replacement can start loading.
            // An old completion must neither supply its bytes nor erase the replacement's handle.
            try await requireEventually { loader.loadCount == 2 && loader.parkedLoadCount == 1 }
            let releasedNew = loader.releaseOne(with: try artworkFixture(width: 64, height: 64))
            #expect(releasedNew)
            try await replacement.requireCompletion()
            #expect(try await replacement.value.pixelWidth == 64)
            let url = artworkURL("replaced")
            let cached = try await pipeline.artwork(
                for: ArtworkRequest(url: url, maximumPixelDimension: 64, accountEpoch: 1))
            let otherSize = try await pipeline.artwork(
                for: ArtworkRequest(url: url, maximumPixelDimension: 128, accountEpoch: 1))
            #expect(cached.pixelWidth == 64)
            #expect(otherSize.pixelWidth == 64)
            #expect(loader.loadCount == 2)
            let stats = await pipeline.statistics()
            #expect(stats.sourceCount == 1)
            #expect(stats.thumbnailCount == 2)
            #expect(stats.thumbnailDecodes == 2)
        }
    }

    @Test(arguments: [false, true])
    @MainActor
    func abandonedArtworkDoesNotRetainItsPipelineWhileLoadingIgnoresCancellation(retire: Bool) async throws {
        let loader = ArtworkFixtureLoader(data: try artworkFixture(width: 16, height: 16), suspended: true)
        try await withArtworkFixture(loader: loader) { fixture in
            weak var released: ArtworkPipeline?
            do {
                let pipeline = ArtworkPipeline(loader: loader)
                await fixture.observe(pipeline)
                released = pipeline
                await pipeline.activate(accountEpoch: 1)
                let caller = await startArtwork(pipeline, fixture: fixture, name: "ignored")
                try await requireEventually { loader.parkedLoadCount == 1 }
                if retire { await pipeline.retire(accountEpoch: 1) } else { caller.cancel() }
                if retire {
                    try await expectRetired(caller)
                } else {
                    try await caller.requireCompletion()
                    await #expect(throws: CancellationError.self) { try await caller.value }
                }
            }
            try await requireEventually { released == nil }
            #expect(loader.parkedLoadCount == 1)
        }
    }

    @Test func ignoredCancelledWorkKeepsCapacityUntilTheSourceActuallyReturns() async throws {
        let loader = ArtworkFixtureLoader(data: try artworkFixture(width: 16, height: 16), suspended: true)
        try await withArtworkFixture(loader: loader) { fixture in
            let pipeline = ArtworkPipeline(loader: loader, maximumActiveRequests: 1)
            await fixture.observe(pipeline)
            await pipeline.activate(accountEpoch: 1)
            let first = await startArtwork(pipeline, fixture: fixture, name: "old")
            try await requireEventually { loader.parkedLoadCount == 1 }
            first.cancel()
            try await first.requireCompletion()
            await #expect(throws: CancellationError.self) { try await first.value }
            let replacement = await startArtwork(pipeline, fixture: fixture, name: "new")
            #expect(await pipeline.statistics().pendingRequests == 1)
            #expect(loader.loadCount == 1)
            loader.releaseAll()
            try await replacement.requireCompletion()
            #expect(try await replacement.value.pixelWidth == 16)
            #expect(loader.loadCount == 2)
            let stats = await pipeline.statistics()
            #expect(stats.sourceCount == 1)
            #expect(stats.thumbnailCount == 1)
            #expect(stats.thumbnailDecodes == 1)
        }
    }

    @Test func sameSizeConsumersShareOneDecodeAndCancelIndependently() async throws {
        let loader = ArtworkFixtureLoader(data: try artworkFixture(width: 16, height: 16), suspended: true)
        try await withArtworkFixture(loader: loader) { fixture in
            let pipeline = ArtworkPipeline(loader: loader)
            await fixture.observe(pipeline)
            await pipeline.activate(accountEpoch: 1)
            let first = await startArtwork(pipeline, fixture: fixture, name: "same")
            let second = await startArtwork(pipeline, fixture: fixture, name: "same")
            try await requireEventually { loader.parkedLoadCount == 1 }
            first.cancel()
            try await first.requireCompletion()
            await #expect(throws: CancellationError.self) { try await first.value }
            loader.releaseAll()
            try await second.requireCompletion()
            #expect(try await second.value.pixelWidth == 16)
            #expect(loader.loadCount == 1)
            #expect(await pipeline.statistics().thumbnailDecodes == 1)
        }
    }

    @Test func replacementSourcesWaitForEveryOlderLoaderCleanup() async throws {
        let cleanup = HarnessResponseGate<Void>()
        let loader = ArtworkFixtureLoader(
            data: try artworkFixture(width: 16, height: 16), suspended: true,
            cleanupGate: cleanup, cancelLoadsOnCleanup: true)
        try await withArtworkFixture(loader: loader) { fixture in
            let pipeline = ArtworkPipeline(loader: loader)
            await fixture.observe(pipeline)
            await pipeline.activate(accountEpoch: 1)
            let firstRetirement = await startArtworkRetirement(pipeline, fixture: fixture)
            try await requireEventually { cleanup.waiterCount == 1 }
            let secondRetirement = await startArtworkRetirement(pipeline, fixture: fixture)
            await pipeline.activate(accountEpoch: 2)
            let replacement = await startArtwork(pipeline, fixture: fixture, name: "replacement", epoch: 2)
            // Source admission is observable even while its physical load awaits old cleanup.
            try await requireEventually { await pipeline.statistics().sourceLoads == 1 }
            cleanup.finish(())
            try await firstRetirement.requireCompletion()
            try await firstRetirement.value
            try await requireEventually { cleanup.waiterCount == 1 }
            let later = await startArtwork(pipeline, fixture: fixture, name: "after-first-cleanup", epoch: 2)
            try await requireEventually { await pipeline.statistics().sourceLoads == 2 }
            cleanup.finish(())
            try await secondRetirement.requireCompletion()
            try await secondRetirement.value
            loader.releaseAll()
            try await replacement.requireCompletion()
            #expect(try await replacement.value.pixelWidth == 16)
            try await later.requireCompletion()
            #expect(try await later.value.pixelWidth == 16)
            #expect(loader.loadsDuringCleanup == 0)
            #expect(loader.cancellationCount == 2)
            #expect(await pipeline.statistics().thumbnailCount == 2)
            await pipeline.retire(accountEpoch: 1)
            #expect(loader.cancellationCount == 2)
        }
    }

    @Test
    func cancellingLastConsumerReleasesSourceCapacityForNewPage() async throws {
        let loader = ArtworkFixtureLoader(
            data: try artworkFixture(width: 16, height: 16), suspended: true, honorsCancellation: true)
        try await withArtworkFixture(loader: loader) { fixture in
            let pipeline = ArtworkPipeline(loader: loader, maximumActiveRequests: 1)
            await fixture.observe(pipeline)
            await pipeline.activate(accountEpoch: 1)
            let previous = await startArtwork(pipeline, fixture: fixture, name: "previous", epoch: 1)
            try await requireEventually { loader.parkedLoadCount == 1 }
            previous.cancel()
            try await previous.requireCompletion()
            await #expect(throws: CancellationError.self) { try await previous.value }
            let current = await startArtwork(pipeline, fixture: fixture, name: "current", epoch: 1)
            try await requireEventually { loader.loadCount == 2 && loader.parkedLoadCount == 1 }
            #expect(loader.cancelledLoadCount == 1)
            #expect(loader.parkedLoadCount == 1)
            loader.releaseAll()
            try await current.requireCompletion()
            #expect(try await current.value.pixelWidth == 16)
            #expect(await pipeline.statistics().sourceCount == 1)
        }
    }

    @Test(arguments: [64, 256], [false, true])
    func cancellingOneVariantPreservesSourceForRemainingConsumer(cancelledSize: Int, honorsCancellation: Bool)
        async throws
    {
        let loader = ArtworkFixtureLoader(
            data: try artworkFixture(width: 640, height: 400), suspended: true, honorsCancellation: honorsCancellation)
        try await withArtworkFixture(loader: loader) { fixture in
            let pipeline = ArtworkPipeline(loader: loader)
            await fixture.observe(pipeline)
            await pipeline.activate(accountEpoch: 1)
            let url = artworkURL("shared-cancellation")
            let first = await startArtwork(pipeline, fixture: fixture, url: url, pixels: 64, epoch: 1)
            try await requireEventually { loader.parkedLoadCount == 1 }
            let second = await startArtwork(pipeline, fixture: fixture, url: url, pixels: 256, epoch: 1)
            try await requireEventually { await pipeline.statistics().pendingRequests == 2 }
            let cancelled = cancelledSize == 64 ? first : second
            let remaining = cancelledSize == 64 ? second : first
            cancelled.cancel()
            try await cancelled.requireCompletion()
            await #expect(throws: CancellationError.self) { try await cancelled.value }
            loader.releaseAll()
            try await remaining.requireCompletion()
            #expect(try await remaining.value.pixelWidth == (cancelledSize == 64 ? 256 : 64))
            #expect(loader.loadCount == 1)
            #expect(loader.cancelledLoadCount == 0)
            #expect(await pipeline.statistics().thumbnailCount == 1)
            #expect(await pipeline.statistics().thumbnailDecodes == 1)
        }
    }

    @Test
    func concurrentArtworkAndTintShareOneSourceAndRetainSizedResults() async throws {
        let loader = ArtworkFixtureLoader(data: try artworkFixture(width: 640, height: 400), suspended: true)
        try await withArtworkFixture(loader: loader) { fixture in
            let pipeline = ArtworkPipeline(loader: loader)
            await fixture.observe(pipeline)
            await pipeline.activate(accountEpoch: 1)
            let url = artworkURL("shared")
            let small = await startArtwork(pipeline, fixture: fixture, url: url, pixels: 64, epoch: 1)
            let large = await startArtwork(pipeline, fixture: fixture, url: url, pixels: 256, epoch: 1)
            try await requireEventually { loader.parkedLoadCount == 1 }
            try await requireEventually { await pipeline.statistics().pendingRequests == 2 }
            loader.releaseAll()
            try await small.requireCompletion()
            try await large.requireCompletion()
            let thumbnail = try await small.value
            let hero = try await large.value
            #expect(thumbnail.pixelWidth == 64)
            #expect(thumbnail.pixelHeight == 40)
            #expect(hero.pixelWidth == 256)
            #expect(hero.pixelHeight == 160)
            #expect(hero.rgbaPixels.count == 256 * 160 * 4)
            #expect(thumbnail.tint?.hue == 0)
            #expect(thumbnail.tint?.saturation == 0.55)
            #expect(thumbnail.tint?.brightness == 0.55)
            #expect(hero.rgbaPixels.prefix(4) == Data([255, 0, 0, 255]))
            #expect(hero.byteCount == 256 * 160 * 4)
            _ = try await pipeline.artwork(for: ArtworkRequest(url: url, maximumPixelDimension: 256, accountEpoch: 1))
            let stats = await pipeline.statistics()
            #expect(stats.sourceLoads == 1)
            #expect(stats.thumbnailDecodes == 2)
            #expect(stats.cacheHits == 1)
            #expect(stats.mainThreadDecodes == 0)
            #expect(stats.residentBytes < 32 * 1_024 * 1_024)
            print(
                "Artwork sharing evidence: sources=\(stats.sourceLoads), decodes=\(stats.thumbnailDecodes), cacheHits=\(stats.cacheHits), mainThreadDecodes=\(stats.mainThreadDecodes), retainedBytes=\(stats.residentBytes), thumbnails=64x40/256x160"
            )
        }
    }

    @Test
    func cacheByteAndEntryBudgetsEvictPriorSourcesAndThumbnails() async throws {
        let loader = ArtworkFixtureLoader(data: try artworkFixture(width: 256, height: 256))
        try await withArtworkFixture(loader: loader) { fixture in
            let budget = 64 * 1_024
            let pipeline = ArtworkPipeline(loader: loader, maximumCacheBytes: budget, maximumCacheEntries: 2)
            await fixture.observe(pipeline)
            await pipeline.activate(accountEpoch: 1)
            for index in 0..<8 {
                _ = try await pipeline.artwork(
                    for: ArtworkRequest(url: artworkURL("bounded-\(index)"), maximumPixelDimension: 64, accountEpoch: 1)
                )
                let stats = await pipeline.statistics()
                #expect(stats.residentBytes <= budget)
                #expect(stats.sourceCount + stats.thumbnailCount <= 2)
            }
            await pipeline.retire(accountEpoch: 1)
            let retired = await pipeline.statistics()
            #expect(retired.residentBytes == 0)
            #expect(retired.sourceCount == 0 && retired.thumbnailCount == 0 && retired.pendingRequests == 0)
        }
    }

    @Test
    func retirementRejectsLateBytesAndOldActivationWithoutErasingReplacementAccount() async throws {
        let loader = ArtworkFixtureLoader(data: try artworkFixture(width: 32, height: 32), suspended: true)
        try await withArtworkFixture(loader: loader) { fixture in
            let pipeline = ArtworkPipeline(loader: loader)
            await fixture.observe(pipeline)
            let url = artworkURL("retired")
            await pipeline.activate(accountEpoch: 1)
            let old = await startArtwork(pipeline, fixture: fixture, url: url, pixels: 64, epoch: 1)
            try await requireEventually { loader.parkedLoadCount == 1 }
            await pipeline.retire(accountEpoch: 1)
            try await expectRetired(old)
            #expect(await pipeline.statistics().residentBytes == 0)
            await pipeline.activate(accountEpoch: 1)
            await #expect(throws: ArtworkFailure.retired) {
                try await pipeline.artwork(for: ArtworkRequest(url: url, maximumPixelDimension: 64, accountEpoch: 1))
            }
            await pipeline.activate(accountEpoch: 2)
            let current = await startArtwork(pipeline, fixture: fixture, url: url, pixels: 64, epoch: 2)
            try await requireEventually {
                let parked = loader.parkedLoadCount
                let loads = loader.loadCount
                return parked == 2 && loads == 2
            }
            loader.releaseAll()
            try await current.requireCompletion()
            #expect(try await current.value.pixelWidth == 32)
            await pipeline.retire(accountEpoch: 1)
            let cached = try await pipeline.artwork(
                for: ArtworkRequest(url: url, maximumPixelDimension: 64, accountEpoch: 2))
            #expect(cached.pixelWidth == 32)
            #expect(await pipeline.statistics().sourceLoads == 2)
            #expect(loader.cancellationCount == 1)
        }
    }

    @Test
    func workCapacityAndQueuedCancellationBoundActualSourceLoads() async throws {
        let loader = ArtworkFixtureLoader(data: try artworkFixture(width: 16, height: 16), suspended: true)
        try await withArtworkFixture(loader: loader) { fixture in
            let pipeline = ArtworkPipeline(loader: loader, maximumActiveRequests: 1, maximumPendingRequests: 2)
            await fixture.observe(pipeline)
            await pipeline.activate(accountEpoch: 7)
            let first = await startArtwork(pipeline, fixture: fixture, name: "first", epoch: 7)
            try await requireEventually { loader.parkedLoadCount == 1 }
            let queued = await startArtwork(pipeline, fixture: fixture, name: "queued", epoch: 7)
            try await requireEventually { await pipeline.statistics().pendingRequests == 2 }
            await #expect(throws: ArtworkFailure.overloaded) {
                try await pipeline.artwork(
                    for: ArtworkRequest(url: artworkURL("overflow"), maximumPixelDimension: 64, accountEpoch: 7))
            }
            queued.cancel()
            try await queued.requireCompletion()
            do { _ = try await queued.value; Issue.record("Cancelled artwork should not reach source loading") } catch {
                #expect(error is CancellationError)
            }
            loader.releaseAll()
            try await first.requireCompletion()
            _ = try await first.value
            #expect(loader.loadCount == 1)
            #expect(await pipeline.statistics().pendingRequests == 0)
        }
    }

    @Test(arguments: [false, true])
    func fixtureCleanupJoinsIgnoredSourceAndSerializedRetirementAfterSuccessOrThrownPrerequisite(
        failsPrerequisite: Bool
    ) async throws {
        let cleanup = HarnessResponseGate<Void>(cancellation: .ignored)
        let loader = ArtworkFixtureLoader(
            data: try artworkFixture(width: 16, height: 16), suspended: true, cleanupGate: cleanup)
        do {
            try await withArtworkFixture(loader: loader) { fixture in
                let pipeline = ArtworkPipeline(loader: loader, maximumActiveRequests: 1)
                await fixture.observe(pipeline)
                await pipeline.activate(accountEpoch: 1)
                _ = await startArtwork(pipeline, fixture: fixture, name: "cleanup-old")
                try await requireEventually { loader.parkedLoadCount == 1 }
                _ = await startArtworkRetirement(pipeline, fixture: fixture)
                try await requireEventually { cleanup.waiterCount == 1 }
                await pipeline.activate(accountEpoch: 2)
                _ = await startArtwork(pipeline, fixture: fixture, name: "cleanup-new", epoch: 2)
                #expect(await pipeline.statistics().pendingRequests == 1)
                #expect(loader.completedLoadCount == 0)
                if failsPrerequisite { throw ArtworkFixtureFailure.prerequisite }
                // Both success and failure leave real work parked for terminal cleanup to join.
            }
            #expect(failsPrerequisite == false)
        } catch {
            #expect(failsPrerequisite)
            #expect(error as? ArtworkFixtureFailure == .prerequisite)
        }
        #expect(loader.completedLoadCount == loader.loadCount)
        #expect(loader.completedCleanupCount == 1)
        #expect(cleanup.waiterCount == 0)
        await #expect(throws: CancellationError.self) { try await loader.load(artworkURL("future")) }
        await #expect(throws: CancellationError.self) { try await cleanup.wait() }
    }

    @Test func fixtureCleanupBeforeRegistrationClosesFutureIgnoredLoads() async throws {
        let loader = ArtworkFixtureLoader(data: try artworkFixture(width: 16, height: 16), suspended: true)
        await #expect(throws: ArtworkFixtureFailure.prerequisite) {
            try await withArtworkFixture(loader: loader) { _ in
                throw ArtworkFixtureFailure.prerequisite
            }
        }
        #expect(loader.loadCount == 0)
        await #expect(throws: CancellationError.self) { try await loader.load(artworkURL("not-yet-registered")) }
        #expect(loader.completedLoadCount == 1)
        #expect(loader.parkedLoadCount == 0)
    }

    @Test func cancelledFixtureScopeJoinsIgnoredSourceAndRetirement() async throws {
        let cleanup = HarnessResponseGate<Void>(cancellation: .ignored)
        let scope = HarnessResponseGate<Void>()
        let loader = ArtworkFixtureLoader(
            data: try artworkFixture(width: 16, height: 16), suspended: true, cleanupGate: cleanup)
        let completed = HarnessCounters()
        defer { scope.close() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    try await withArtworkFixture(loader: loader, closing: { scope.close() }) { fixture in
                        let pipeline = ArtworkPipeline(loader: loader)
                        await fixture.observe(pipeline)
                        await pipeline.activate(accountEpoch: 1)
                        _ = await startArtwork(pipeline, fixture: fixture, name: "cancelled-scope")
                        try await requireEventually { loader.parkedLoadCount == 1 }
                        _ = await startArtworkRetirement(pipeline, fixture: fixture)
                        try await requireEventually { cleanup.waiterCount == 1 }
                        try await scope.wait()
                    }
                    Issue.record("The fixture scope must observe cancellation")
                } catch is CancellationError {
                    completed.record("scope")
                }
            }
            try await requireEventually { scope.waiterCount == 1 }
            group.cancelAll()
            _ = try await group.next()
        }
        #expect(completed.count("scope") == 1)
        #expect(loader.completedLoadCount == 1)
        #expect(loader.completedCleanupCount == 1)
        #expect(loader.parkedLoadCount == 0)
        #expect(cleanup.waiterCount == 0)
    }

    @Test
    func fileFixturesRequireExplicitOptInAndRespectSourceByteLimit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.png")
        let data = try artworkFixture(width: 32, height: 16)
        try data.write(to: url)
        let live = ArtworkSourceLoader()
        await #expect(throws: ArtworkFailure.unsupportedURL) { try await live.load(url) }
        let bounded = ArtworkSourceLoader(maximumSourceBytes: 8, allowFileURLs: true)
        await #expect(throws: ArtworkFailure.tooLarge) { try await bounded.load(url) }
        let demo = ArtworkPipeline(allowFileURLs: true)
        await demo.activate(accountEpoch: 1)
        let value = try await demo.artwork(for: ArtworkRequest(url: url, maximumPixelDimension: 64, accountEpoch: 1))
        #expect(value.pixelWidth == 32 && value.pixelHeight == 16)
        await demo.retire(accountEpoch: 1)
        #expect(await demo.statistics().residentBytes == 0)
    }
}

/// The loader has an intricate per-load script (successful FIFO replies, ignored cancellation,
/// and serialized cleanup), so the fixture composes shared response gates rather than a shared fake.
private final class ArtworkFixtureLoader: ArtworkSourceLoading {
    private struct State {
        var suspended: Bool
        var closed = false
        var loadCount = 0
        var completedLoadCount = 0
        var cancellationCount = 0
        var completedCleanupCount = 0
        var cancelledLoadCount = 0
        var loadsDuringCleanup = 0
        var activeCleanups = 0
        var gates: [HarnessResponseGate<Data>] = []
    }

    let data: Data
    private let state: Mutex<State>
    private let honorsCancellation: Bool
    private let cleanupGate: HarnessResponseGate<Void>?
    private let cancelLoadsOnCleanup: Bool

    var parkedLoadCount: Int { state.withLock { $0.gates.reduce(0) { $0 + $1.waiterCount } } }
    var loadCount: Int { state.withLock { $0.loadCount } }
    var completedLoadCount: Int { state.withLock { $0.completedLoadCount } }
    var cancellationCount: Int { state.withLock { $0.cancellationCount } }
    var completedCleanupCount: Int { state.withLock { $0.completedCleanupCount } }
    var cancelledLoadCount: Int { state.withLock { $0.cancelledLoadCount } }
    var loadsDuringCleanup: Int { state.withLock { $0.loadsDuringCleanup } }

    init(
        data: Data, suspended: Bool = false, honorsCancellation: Bool = false,
        cleanupGate: HarnessResponseGate<Void>? = nil, cancelLoadsOnCleanup: Bool = false
    ) {
        self.data = data
        state = Mutex(State(suspended: suspended))
        self.honorsCancellation = honorsCancellation
        self.cleanupGate = cleanupGate
        self.cancelLoadsOnCleanup = cancelLoadsOnCleanup
    }

    func load(_: URL) async throws -> Data {
        let gate = HarnessResponseGate<Data>(cancellation: honorsCancellation ? .cooperative : .ignored)
        let admission = state.withLock { state -> (closed: Bool, suspended: Bool) in
            state.loadCount += 1
            if state.activeCleanups > 0 { state.loadsDuringCleanup += 1 }
            if state.suspended && !state.closed { state.gates.append(gate) }
            return (state.closed, state.suspended)
        }
        defer {
            state.withLock {
                $0.gates.removeAll { $0 === gate }
                $0.completedLoadCount += 1
            }
        }
        guard !admission.closed else { throw CancellationError() }
        guard admission.suspended else { return data }
        do {
            return try await gate.wait()
        } catch {
            if honorsCancellation && Task.isCancelled {
                state.withLock { $0.cancelledLoadCount += 1 }
            }
            throw error
        }
    }

    func cancelAll() async {
        state.withLock {
            $0.cancellationCount += 1
            $0.activeCleanups += 1
        }
        defer {
            state.withLock {
                $0.activeCleanups -= 1
                $0.completedCleanupCount += 1
            }
        }
        if let cleanupGate { _ = try? await cleanupGate.wait() }
        if cancelLoadsOnCleanup {
            let gates = state.withLock { $0.gates }
            gates.forEach { $0.close() }
        }
    }

    /// Normal success admits future loads; it is intentionally separate from terminal closure.
    func releaseAll() {
        let gates = state.withLock {
            $0.suspended = false
            return $0.gates
        }
        gates.forEach { $0.finish(data) }
    }

    func releaseOne(with data: Data) -> Bool {
        guard let gate = state.withLock({ $0.gates.first { $0.waiterCount > 0 } }) else { return false }
        gate.finish(data)
        return true
    }

    /// Close every admission before cancelling or joining any task, including not-yet-entered loads.
    func close() {
        let gates = state.withLock {
            $0.closed = true
            return $0.gates
        }
        cleanupGate?.close()
        gates.forEach { $0.close() }
    }
}

private enum ArtworkFixtureFailure: Error, Equatable { case prerequisite }

/// Only the actual caller records completion. The marker bounds pre-cleanup observation while
/// the stored Task remains the authority for joining work; it stores no result or pipeline owner.
private struct ArtworkCaller<Value: Sendable, Failure: Error>: Sendable {
    let task: Task<Value, Failure>
    let completion: HarnessCounters

    var value: Value {
        get async throws { try await task.value }
    }

    func cancel() { task.cancel() }

    func requireCompletion(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await requireEventually(
            description: "Artwork caller completes before its parked source is released",
            sourceLocation: sourceLocation
        ) { completion.count("finished") == 1 }
    }
}

private final class ArtworkFixtureOwner: Sendable {
    private enum Caller: Sendable {
        case artwork(ArtworkCaller<ArtworkAsset, any Error>)
        case retirement(ArtworkCaller<Void, Never>)

        func cancel() {
            switch self {
            case let .artwork(task): task.cancel()
            case let .retirement(task): task.cancel()
            }
        }

        func wait() async {
            switch self {
            case let .artwork(caller): _ = await caller.task.result
            case let .retirement(caller): await caller.task.value
            }
        }
    }

    private struct State {
        var closing = false
        var callers: [Caller] = []
        var workers: [ArtworkPipeline.WorkReceipt] = []
        var joinedCallers = 0
        var joinedWorkers = 0
    }

    let loader: ArtworkFixtureLoader
    private let state = Mutex(State())
    private let closing: @Sendable () -> Void

    init(loader: ArtworkFixtureLoader, closing: @escaping @Sendable () -> Void) {
        self.loader = loader
        self.closing = closing
    }

    func observe(_ pipeline: ArtworkPipeline) async {
        // The observer captures only the fixture. Source/thumbnail workers keep their weak owner;
        // existing cancellation tasks release their temporary owner when their actor call ends.
        await pipeline.observeWork { [self] receipt in
            let closing = state.withLock {
                $0.workers.append(receipt)
                return $0.closing
            }
            if closing { receipt.cancel() }
        }
    }

    func own(_ task: ArtworkCaller<ArtworkAsset, any Error>) -> ArtworkCaller<ArtworkAsset, any Error> {
        let closing = state.withLock {
            $0.callers.append(.artwork(task))
            return $0.closing
        }
        if closing { task.cancel() }
        return task
    }

    func own(_ task: ArtworkCaller<Void, Never>) -> ArtworkCaller<Void, Never> {
        let closing = state.withLock {
            $0.callers.append(.retirement(task))
            return $0.closing
        }
        if closing { task.cancel() }
        return task
    }

    func cleanUp() async {
        loader.close()
        closing()
        let accepted = state.withLock {
            $0.closing = true
            return ($0.callers, $0.workers)
        }
        accepted.0.forEach { $0.cancel() }
        accepted.1.forEach { $0.cancel() }
        // Callers can settle before noncooperative source/decode work. Join both, and drain actual
        // cancellation/worker handles reported while previous joins run rather than polling counts.
        for caller in accepted.0 {
            await caller.wait()
            state.withLock { $0.joinedCallers += 1 }
        }
        var index = 0
        while let worker = state.withLock({ index < $0.workers.count ? $0.workers[index] : nil }) {
            worker.cancel()
            await worker.wait()
            state.withLock { $0.joinedWorkers += 1 }
            index += 1
        }
        let counts = state.withLock { ($0.callers.count, $0.joinedCallers, $0.workers.count, $0.joinedWorkers) }
        #expect(counts.0 == counts.1)
        #expect(counts.2 == counts.3)
        #expect(loader.completedLoadCount == loader.loadCount)
        #expect(loader.completedCleanupCount == loader.cancellationCount)
        #expect(loader.parkedLoadCount == 0)
    }
}

private func withArtworkFixture(
    isolation: isolated (any Actor)? = #isolation,
    loader: ArtworkFixtureLoader,
    closing: @escaping @Sendable () -> Void = {},
    _ body: (ArtworkFixtureOwner) async throws -> Void
) async throws {
    let fixture = ArtworkFixtureOwner(loader: loader, closing: closing)
    do {
        try await body(fixture)
    } catch {
        await fixture.cleanUp()
        throw error
    }
    await fixture.cleanUp()
}

// Immediate tasks register their caller before these isolated helpers return, so same-bucket
// joins and overlapping retirements need no private waiter counters or scheduling sleeps.
private func startArtwork(
    _ pipeline: isolated ArtworkPipeline, fixture: ArtworkFixtureOwner,
    name: String, epoch: UInt64 = 1
) -> ArtworkCaller<ArtworkAsset, any Error> {
    startArtwork(pipeline, fixture: fixture, url: artworkURL(name), epoch: epoch)
}

private func startArtwork(
    _ pipeline: isolated ArtworkPipeline, fixture: ArtworkFixtureOwner,
    url: URL, pixels: Int = 64, epoch: UInt64 = 1
) -> ArtworkCaller<ArtworkAsset, any Error> {
    let completion = HarnessCounters()
    let task = Task.immediate {
        defer { completion.record("finished") }
        return try await pipeline.artwork(
            for: ArtworkRequest(url: url, maximumPixelDimension: pixels, accountEpoch: epoch))
    }
    return fixture.own(ArtworkCaller(task: task, completion: completion))
}

private func startArtworkRetirement(
    _ pipeline: isolated ArtworkPipeline, fixture: ArtworkFixtureOwner
) -> ArtworkCaller<Void, Never> {
    let completion = HarnessCounters()
    let task = Task.immediate {
        defer { completion.record("finished") }
        await pipeline.retire(accountEpoch: 1)
    }
    return fixture.own(ArtworkCaller(task: task, completion: completion))
}

private func artworkFixture(width: Int, height: Int) throws -> Data {
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(try #require(CGColor(colorSpace: colorSpace, components: [1, 0, 0, 1])))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let encoded = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return encoded as Data
}

private func artworkURL(_ name: String) -> URL { URL(string: "https://fixtures.invalid/\(name).png")! }
private func expectRetired(_ task: ArtworkCaller<ArtworkAsset, any Error>) async throws {
    try await task.requireCompletion()
    do { _ = try await task.value; Issue.record("Retired artwork must never publish") } catch {
        #expect(error as? ArtworkFailure == .retired)
    }
}
