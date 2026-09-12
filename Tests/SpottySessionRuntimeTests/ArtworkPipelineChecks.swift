import CoreGraphics
import Foundation
import ImageIO
import SpottyRuntimeContracts
import Testing
@testable import SpottySessionRuntime

@Suite("Account artwork pipeline")
struct ArtworkPipelineTests {
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
        #expect(await artworkWait { await loader.loadCount == 1 })
        #expect(await artworkWait { await pipeline.statistics().pendingRequests == 2 })
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
        let encoded = try #require(CGImageSourceCreateWithData(hero.encodedThumbnail as CFData, nil))
        #expect(CGImageSourceGetCount(encoded) == 1)
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
        #expect(await artworkWait { await loader.loadCount == 1 })
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
        #expect(await artworkWait { await loader.loadCount == 2 })
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
        #expect(await artworkWait { await loader.loadCount == 1 })
        let queued = Task {
            try await pipeline.artwork(
                for: ArtworkRequest(url: artworkURL("queued"), maximumPixelDimension: 64, accountEpoch: 7))
        }
        #expect(await artworkWait { await pipeline.statistics().pendingRequests == 2 })
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
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(data: Data, suspended: Bool = false) { self.data = data; self.suspended = suspended }
    func load(_: URL) async -> Data {
        loadCount += 1
        if suspended { await withCheckedContinuation { waiters.append($0) } }
        return data
    }
    func cancelAll() { cancellationCount += 1 }
    func releaseAll() {
        suspended = false
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
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
private func artworkWait(_ predicate: () async -> Bool) async -> Bool {
    for _ in 0..<10_000 {
        if await predicate() { return true }
        await Task.yield()
    }
    return false
}
private func expectRetired(_ task: Task<ArtworkAsset, any Error>) async {
    do { _ = try await task.value; Issue.record("Retired artwork must never publish") } catch {
        #expect(error as? ArtworkFailure == .retired)
    }
}
