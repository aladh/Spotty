import SpottyTestSupport
import CoreGraphics
import Foundation
import ImageIO
import SpottyRuntimeContracts
import Testing
@testable import SpottySessionRuntime

@Suite("Account artwork pipeline")
struct ArtworkPipelineTests {
    @Test func sameAccountSameSizeReplacementKeepsItsOwnSourceAndThumbnail() async throws {
        let loader = ArtworkFixtureLoader(data: try artworkFixture(width: 16, height: 16), suspended: true)
        let pipeline = ArtworkPipeline(loader: loader, maximumActiveRequests: 1)
        await pipeline.activate(accountEpoch: 1)
        let first = await startArtwork(pipeline, name: "replaced")
        defer { first.cancel(); Task { await loader.releaseAll() } }
        try await requireEventually { await loader.parkedLoadCount == 1 }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        let replacement = await startArtwork(pipeline, name: "replaced")
        defer { replacement.cancel() }
        #expect(await pipeline.statistics().pendingRequests == 1)
        let releasedOld = await loader.releaseOne(with: try artworkFixture(width: 16, height: 16))
        #expect(releasedOld)
        // Capacity one makes the old source settle before the replacement can start loading.
        // An old completion must neither supply its bytes nor erase the replacement's handle.
        try await requireEventually { await loader.loadCount == 2 }
        let releasedNew = await loader.releaseOne(with: try artworkFixture(width: 64, height: 64))
        #expect(releasedNew)
        #expect(try await replacement.value.pixelWidth == 64)
        let url = artworkURL("replaced")
        let cached = try await pipeline.artwork(
            for: ArtworkRequest(url: url, maximumPixelDimension: 64, accountEpoch: 1))
        let otherSize = try await pipeline.artwork(
            for: ArtworkRequest(url: url, maximumPixelDimension: 128, accountEpoch: 1))
        #expect(cached.pixelWidth == 64)
        #expect(otherSize.pixelWidth == 64)
        #expect(await loader.loadCount == 2)
        let stats = await pipeline.statistics()
        #expect(stats.sourceCount == 1)
        #expect(stats.thumbnailCount == 2)
        #expect(stats.thumbnailDecodes == 2)
    }

    @Test(arguments: [false, true])
    @MainActor
    func abandonedArtworkDoesNotRetainItsPipelineWhileLoadingIgnoresCancellation(retire: Bool) async throws {
        let loader = ArtworkFixtureLoader(data: try artworkFixture(width: 16, height: 16), suspended: true)
        defer { Task { await loader.releaseAll() } }
        let completed = HarnessCounters()
        weak var released: ArtworkPipeline?
        do {
            let pipeline = ArtworkPipeline(loader: loader)
            released = pipeline
            await pipeline.activate(accountEpoch: 1)
            let caller = Task {
                defer { completed.record("caller") }
                return try? await pipeline.artwork(
                    for: ArtworkRequest(url: artworkURL("ignored"), maximumPixelDimension: 64, accountEpoch: 1))
            }
            defer { caller.cancel() }
            try await requireEventually { await loader.parkedLoadCount == 1 }
            if retire { await pipeline.retire(accountEpoch: 1) } else { caller.cancel() }
            try await requireEventually { completed.count("caller") == 1 }
            #expect(await caller.value == nil)
        }
        try await requireEventually { released == nil }
        #expect(await loader.parkedLoadCount == 1)
    }

    @Test func ignoredCancelledWorkKeepsCapacityUntilTheSourceActuallyReturns() async throws {
        let loader = ArtworkFixtureLoader(data: try artworkFixture(width: 16, height: 16), suspended: true)
        let pipeline = ArtworkPipeline(loader: loader, maximumActiveRequests: 1)
        await pipeline.activate(accountEpoch: 1)
        let first = await startArtwork(pipeline, name: "old")
        defer { first.cancel(); Task { await loader.releaseAll() } }
        try await requireEventually { await loader.parkedLoadCount == 1 }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        let replacement = await startArtwork(pipeline, name: "new")
        defer { replacement.cancel() }
        #expect(await pipeline.statistics().pendingRequests == 1)
        #expect(await loader.loadCount == 1)
        await loader.releaseAll()
        #expect(try await replacement.value.pixelWidth == 16)
        #expect(await loader.loadCount == 2)
        let stats = await pipeline.statistics()
        #expect(stats.sourceCount == 1)
        #expect(stats.thumbnailCount == 1)
        #expect(stats.thumbnailDecodes == 1)
    }

    @Test func sameSizeConsumersShareOneDecodeAndCancelIndependently() async throws {
        let loader = ArtworkFixtureLoader(data: try artworkFixture(width: 16, height: 16), suspended: true)
        let pipeline = ArtworkPipeline(loader: loader)
        await pipeline.activate(accountEpoch: 1)
        let first = await startArtwork(pipeline, name: "same")
        let second = await startArtwork(pipeline, name: "same")
        defer { first.cancel(); second.cancel(); Task { await loader.releaseAll() } }
        try await requireEventually { await loader.parkedLoadCount == 1 }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        await loader.releaseAll()
        #expect(try await second.value.pixelWidth == 16)
        #expect(await loader.loadCount == 1)
        #expect(await pipeline.statistics().thumbnailDecodes == 1)
    }

    @Test func replacementSourcesWaitForEveryOlderLoaderCleanup() async throws {
        let cleanup = HarnessResponseGate<Void>()
        let loader = ArtworkFixtureLoader(
            data: try artworkFixture(width: 16, height: 16), suspended: true,
            cleanupGate: cleanup, cancelLoadsOnCleanup: true)
        defer { cleanup.close(); Task { await loader.releaseAll() } }
        let pipeline = ArtworkPipeline(loader: loader)
        await pipeline.activate(accountEpoch: 1)
        let firstRetirement = await startArtworkRetirement(pipeline)
        defer { firstRetirement.cancel() }
        try await requireEventually { cleanup.waiterCount == 1 }
        let secondRetirement = await startArtworkRetirement(pipeline)
        defer { secondRetirement.cancel() }
        await pipeline.activate(accountEpoch: 2)
        let replacement = await startArtwork(pipeline, name: "replacement", epoch: 2)
        defer { replacement.cancel() }
        // Source admission is observable even while its physical load awaits old cleanup.
        try await requireEventually { await pipeline.statistics().sourceLoads == 1 }
        cleanup.finish(())
        await firstRetirement.value
        try await requireEventually { cleanup.waiterCount == 1 }
        let later = await startArtwork(pipeline, name: "after-first-cleanup", epoch: 2)
        defer { later.cancel() }
        try await requireEventually { await pipeline.statistics().sourceLoads == 2 }
        cleanup.finish(())
        await secondRetirement.value
        await loader.releaseAll()
        #expect(try await replacement.value.pixelWidth == 16)
        #expect(try await later.value.pixelWidth == 16)
        #expect(await loader.loadsDuringCleanup == 0)
        #expect(await loader.cancellationCount == 2)
        #expect(await pipeline.statistics().thumbnailCount == 2)
        await pipeline.retire(accountEpoch: 1)
        #expect(await loader.cancellationCount == 2)
    }

    @Test
    func cancellingLastConsumerReleasesSourceCapacityForNewPage() async throws {
        let loader = ArtworkFixtureLoader(
            data: try artworkFixture(width: 16, height: 16), suspended: true, honorsCancellation: true)
        let pipeline = ArtworkPipeline(loader: loader, maximumActiveRequests: 1)
        await pipeline.activate(accountEpoch: 1)
        let previous = Task {
            try await pipeline.artwork(
                for: ArtworkRequest(url: artworkURL("previous"), maximumPixelDimension: 64, accountEpoch: 1))
        }
        defer {
            previous.cancel()
            Task { await loader.releaseAll() }
        }
        try await requireEventually { await loader.parkedLoadCount == 1 }
        previous.cancel()
        await #expect(throws: CancellationError.self) { try await previous.value }
        let current = Task {
            try await pipeline.artwork(
                for: ArtworkRequest(url: artworkURL("current"), maximumPixelDimension: 64, accountEpoch: 1))
        }
        defer { current.cancel() }
        try await requireEventually { await loader.loadCount == 2 }
        #expect(await loader.cancelledLoadCount == 1)
        #expect(await loader.parkedLoadCount == 1)
        await loader.releaseAll()
        #expect(try await current.value.pixelWidth == 16)
        #expect(await pipeline.statistics().sourceCount == 1)
    }

    @Test(arguments: [64, 256], [false, true])
    func cancellingOneVariantPreservesSourceForRemainingConsumer(cancelledSize: Int, honorsCancellation: Bool)
        async throws
    {
        let loader = ArtworkFixtureLoader(
            data: try artworkFixture(width: 640, height: 400), suspended: true, honorsCancellation: honorsCancellation)
        let pipeline = ArtworkPipeline(loader: loader)
        await pipeline.activate(accountEpoch: 1)
        let url = artworkURL("shared-cancellation")
        let first = Task {
            try await pipeline.artwork(for: ArtworkRequest(url: url, maximumPixelDimension: 64, accountEpoch: 1))
        }
        defer {
            first.cancel()
            Task { await loader.releaseAll() }
        }
        try await requireEventually { await loader.parkedLoadCount == 1 }
        let second = Task {
            try await pipeline.artwork(for: ArtworkRequest(url: url, maximumPixelDimension: 256, accountEpoch: 1))
        }
        defer { second.cancel() }
        try await requireEventually { await pipeline.statistics().pendingRequests == 2 }
        let cancelled = cancelledSize == 64 ? first : second
        let remaining = cancelledSize == 64 ? second : first
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        await loader.releaseAll()
        #expect(try await remaining.value.pixelWidth == (cancelledSize == 64 ? 256 : 64))
        #expect(await loader.loadCount == 1)
        #expect(await loader.cancelledLoadCount == 0)
        #expect(await pipeline.statistics().thumbnailCount == 1)
        #expect(await pipeline.statistics().thumbnailDecodes == 1)
    }

    @Test
    func concurrentArtworkAndTintShareOneSourceAndRetainSizedResults() async throws {
        let loader = ArtworkFixtureLoader(data: try artworkFixture(width: 640, height: 400), suspended: true)
        let pipeline = ArtworkPipeline(loader: loader)
        await pipeline.activate(accountEpoch: 1)
        let url = artworkURL("shared")
        let small = Task {
            try await pipeline.artwork(for: ArtworkRequest(url: url, maximumPixelDimension: 64, accountEpoch: 1))
        }
        let large = Task {
            try await pipeline.artwork(for: ArtworkRequest(url: url, maximumPixelDimension: 256, accountEpoch: 1))
        }
        defer {
            small.cancel(); large.cancel()
            Task { await loader.releaseAll() }
        }
        try await requireEventually { await loader.parkedLoadCount == 1 }
        try await requireEventually { await pipeline.statistics().pendingRequests == 2 }
        await loader.releaseAll()
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

    @Test
    func cacheByteAndEntryBudgetsEvictPriorSourcesAndThumbnails() async throws {
        let loader = ArtworkFixtureLoader(data: try artworkFixture(width: 256, height: 256))
        let budget = 64 * 1_024
        let pipeline = ArtworkPipeline(loader: loader, maximumCacheBytes: budget, maximumCacheEntries: 2)
        await pipeline.activate(accountEpoch: 1)
        for index in 0..<8 {
            _ = try await pipeline.artwork(
                for: ArtworkRequest(url: artworkURL("bounded-\(index)"), maximumPixelDimension: 64, accountEpoch: 1))
            let stats = await pipeline.statistics()
            #expect(stats.residentBytes <= budget)
            #expect(stats.sourceCount + stats.thumbnailCount <= 2)
        }
        await pipeline.retire(accountEpoch: 1)
        let retired = await pipeline.statistics()
        #expect(retired.residentBytes == 0)
        #expect(retired.sourceCount == 0 && retired.thumbnailCount == 0 && retired.pendingRequests == 0)
    }

    @Test
    func retirementRejectsLateBytesAndOldActivationWithoutErasingReplacementAccount() async throws {
        let loader = ArtworkFixtureLoader(data: try artworkFixture(width: 32, height: 32), suspended: true)
        let pipeline = ArtworkPipeline(loader: loader)
        let url = artworkURL("retired")
        await pipeline.activate(accountEpoch: 1)
        let old = Task {
            try await pipeline.artwork(for: ArtworkRequest(url: url, maximumPixelDimension: 64, accountEpoch: 1))
        }
        defer {
            old.cancel()
            Task { await loader.releaseAll() }
        }
        try await requireEventually { await loader.parkedLoadCount == 1 }
        await pipeline.retire(accountEpoch: 1)
        await expectRetired(old)
        #expect(await pipeline.statistics().residentBytes == 0)
        await pipeline.activate(accountEpoch: 1)
        await #expect(throws: ArtworkFailure.retired) {
            try await pipeline.artwork(for: ArtworkRequest(url: url, maximumPixelDimension: 64, accountEpoch: 1))
        }
        await pipeline.activate(accountEpoch: 2)
        let current = Task {
            try await pipeline.artwork(for: ArtworkRequest(url: url, maximumPixelDimension: 64, accountEpoch: 2))
        }
        defer {
            current.cancel()
            Task { await loader.releaseAll() }
        }
        try await requireEventually {
            let parked = await loader.parkedLoadCount
            let loads = await loader.loadCount
            return parked == 2 && loads == 2
        }
        await loader.releaseAll()
        #expect(try await current.value.pixelWidth == 32)
        await pipeline.retire(accountEpoch: 1)
        let cached = try await pipeline.artwork(
            for: ArtworkRequest(url: url, maximumPixelDimension: 64, accountEpoch: 2))
        #expect(cached.pixelWidth == 32)
        #expect(await pipeline.statistics().sourceLoads == 2)
        #expect(await loader.cancellationCount == 1)
    }

    @Test
    func workCapacityAndQueuedCancellationBoundActualSourceLoads() async throws {
        let loader = ArtworkFixtureLoader(data: try artworkFixture(width: 16, height: 16), suspended: true)
        let pipeline = ArtworkPipeline(loader: loader, maximumActiveRequests: 1, maximumPendingRequests: 2)
        await pipeline.activate(accountEpoch: 7)
        let first = Task {
            try await pipeline.artwork(
                for: ArtworkRequest(url: artworkURL("first"), maximumPixelDimension: 64, accountEpoch: 7))
        }
        defer {
            first.cancel()
            Task { await loader.releaseAll() }
        }
        try await requireEventually { await loader.parkedLoadCount == 1 }
        let queued = Task {
            try await pipeline.artwork(
                for: ArtworkRequest(url: artworkURL("queued"), maximumPixelDimension: 64, accountEpoch: 7))
        }
        defer { queued.cancel() }
        try await requireEventually { await pipeline.statistics().pendingRequests == 2 }
        await #expect(throws: ArtworkFailure.overloaded) {
            try await pipeline.artwork(
                for: ArtworkRequest(url: artworkURL("overflow"), maximumPixelDimension: 64, accountEpoch: 7))
        }
        queued.cancel()
        do { _ = try await queued.value; Issue.record("Cancelled artwork should not reach source loading") } catch {
            #expect(error is CancellationError)
        }
        await loader.releaseAll()
        _ = try await first.value
        #expect(await loader.loadCount == 1)
        #expect(await pipeline.statistics().pendingRequests == 0)
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

private actor ArtworkFixtureLoader: ArtworkSourceLoading {
    let data: Data
    var suspended: Bool
    var loadCount = 0
    var cancellationCount = 0
    var cancelledLoadCount = 0
    var loadsDuringCleanup = 0
    private let honorsCancellation: Bool
    private let cleanupGate: HarnessResponseGate<Void>?
    private let cancelLoadsOnCleanup: Bool
    private var activeCleanups = 0
    private var waiters: [UUID: CheckedContinuation<Data, any Error>] = [:]

    var parkedLoadCount: Int { waiters.count }

    init(
        data: Data, suspended: Bool = false, honorsCancellation: Bool = false,
        cleanupGate: HarnessResponseGate<Void>? = nil, cancelLoadsOnCleanup: Bool = false
    ) {
        self.data = data
        self.suspended = suspended
        self.honorsCancellation = honorsCancellation
        self.cleanupGate = cleanupGate
        self.cancelLoadsOnCleanup = cancelLoadsOnCleanup
    }
    func load(_: URL) async throws -> Data {
        loadCount += 1
        if activeCleanups > 0 { loadsDuringCleanup += 1 }
        if suspended {
            let id = UUID()
            return try await withTaskCancellationHandler {
                if honorsCancellation { try Task.checkCancellation() }
                return try await withCheckedThrowingContinuation { waiters[id] = $0 }
            } onCancel: {
                Task { await self.cancel(id) }
            }
        }
        return data
    }
    private func cancel(_ id: UUID) {
        guard honorsCancellation, let waiter = waiters.removeValue(forKey: id) else { return }
        cancelledLoadCount += 1
        waiter.resume(throwing: CancellationError())
    }
    func cancelAll() async {
        cancellationCount += 1
        activeCleanups += 1
        defer { activeCleanups -= 1 }
        if let cleanupGate { _ = try? await cleanupGate.wait() }
        if cancelLoadsOnCleanup {
            let pending = waiters.values
            waiters.removeAll()
            pending.forEach { $0.resume(throwing: CancellationError()) }
        }
    }
    func releaseAll() {
        suspended = false
        let pending = waiters.values
        waiters.removeAll()
        pending.forEach { $0.resume(returning: data) }
    }
    func releaseOne(with data: Data) -> Bool {
        guard let (id, waiter) = waiters.first else { return false }
        waiters[id] = nil
        waiter.resume(returning: data)
        return true
    }
}

// Immediate tasks register their caller before these isolated helpers return, so same-bucket
// joins and overlapping retirements need no private waiter counters or scheduling sleeps.
private func startArtwork(
    _ pipeline: isolated ArtworkPipeline, name: String, epoch: UInt64 = 1
) -> Task<ArtworkAsset, any Error> {
    Task.immediate {
        try await pipeline.artwork(
            for: ArtworkRequest(url: artworkURL(name), maximumPixelDimension: 64, accountEpoch: epoch))
    }
}

private func startArtworkRetirement(_ pipeline: isolated ArtworkPipeline) -> Task<Void, Never> {
    Task.immediate { await pipeline.retire(accountEpoch: 1) }
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
private func expectRetired(_ task: Task<ArtworkAsset, any Error>) async {
    do { _ = try await task.value; Issue.record("Retired artwork must never publish") } catch {
        #expect(error as? ArtworkFailure == .retired)
    }
}
