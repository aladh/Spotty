import Foundation
import SpottyRuntimeContracts

/// One account owns all artwork source and derivative bytes. Four bounded work items may fetch or
/// decode concurrently; the cache retains at most 32 MiB / 256 entries and never writes to disk.
package actor ArtworkPipeline: ArtworkProviding {
    struct Statistics: Sendable {
        let residentBytes: Int
        let sourceCount: Int
        let thumbnailCount: Int
        let pendingRequests: Int
        let sourceLoads: Int
        let thumbnailDecodes: Int
        let mainThreadDecodes: Int
        let cacheHits: Int
    }

    private struct Key: Hashable, Sendable {
        let url: URL
        let pixels: Int
    }
    private struct Cached<Value> {
        let value: Value
        let bytes: Int
        var lastAccess: UInt64
    }
    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<ArtworkAsset, any Error>]
    }
    private struct SourceFlight {
        let id: UUID
        let task: Task<Data, any Error>
    }

    private let loader: any ArtworkSourceLoading
    private let decoder = ArtworkDecoder()
    private let limiter: ArtworkWorkLimiter
    private let maximumCacheBytes: Int
    private let maximumCacheEntries: Int
    private let maximumPendingRequests: Int
    private var highestEpoch: UInt64 = 0
    private var retiredThrough: UInt64?
    private var activeEpoch: UInt64?
    private var sources: [URL: Cached<Data>] = [:]
    private var thumbnails: [Key: Cached<ArtworkAsset>] = [:]
    private var flights: [Key: Flight] = [:]
    private var sourceFlights: [URL: SourceFlight] = [:]
    private var accessCounter: UInt64 = 0
    private var residentBytes = 0
    private var sourceLoads = 0
    private var thumbnailDecodes = 0
    private var cacheHits = 0

    package init(allowFileURLs: Bool = false) {
        loader = ArtworkSourceLoader(allowFileURLs: allowFileURLs)
        limiter = ArtworkWorkLimiter(maximumActive: 4)
        maximumCacheBytes = 32 * 1_024 * 1_024
        maximumCacheEntries = 256
        maximumPendingRequests = 128
    }

    init(
        loader: any ArtworkSourceLoading,
        maximumCacheBytes: Int = 32 * 1_024 * 1_024,
        maximumCacheEntries: Int = 256,
        maximumActiveRequests: Int = 4,
        maximumPendingRequests: Int = 128
    ) {
        precondition(maximumCacheBytes >= 0 && maximumCacheEntries >= 0 && maximumPendingRequests > 0)
        self.loader = loader
        limiter = ArtworkWorkLimiter(maximumActive: maximumActiveRequests)
        self.maximumCacheBytes = maximumCacheBytes
        self.maximumCacheEntries = maximumCacheEntries
        self.maximumPendingRequests = maximumPendingRequests
    }

    package func activate(accountEpoch: UInt64) {
        guard accountEpoch >= highestEpoch, retiredThrough.map({ accountEpoch > $0 }) ?? true else { return }
        guard activeEpoch != accountEpoch else { return }
        clearOwnedBytes()
        highestEpoch = accountEpoch
        activeEpoch = accountEpoch
    }

    package func retire(accountEpoch: UInt64) async {
        retiredThrough = max(retiredThrough ?? 0, accountEpoch)
        guard accountEpoch >= highestEpoch else { return }
        highestEpoch = accountEpoch
        activeEpoch = nil
        clearOwnedBytes()
        await loader.cancelAll()
    }

    package func artwork(for request: ArtworkRequest) async throws -> ArtworkAsset {
        try Task.checkCancellation()
        try requireCurrent(request.accountEpoch)
        guard request.url.absoluteString.utf8.count <= 8_192 else { throw ArtworkFailure.unsupportedURL }
        let key = Key(url: request.url, pixels: Self.pixelBucket(request.maximumPixelDimension))
        if var cached = thumbnails[key] {
            cached.lastAccess = tick()
            thumbnails[key] = cached
            cacheHits += 1
            return cached.value
        }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard flights.values.reduce(0, { $0 + $1.waiters.count }) < maximumPendingRequests * 4 else {
                    continuation.resume(throwing: ArtworkFailure.overloaded)
                    return
                }
                if var flight = flights[key] {
                    flight.waiters[waiterID] = continuation
                    flights[key] = flight
                    return
                }
                guard flights.count < maximumPendingRequests else {
                    continuation.resume(throwing: ArtworkFailure.overloaded)
                    return
                }
                let id = UUID()
                let task = Task { [weak self, limiter] in
                    guard let self else { return }
                    let result: Result<ArtworkAsset, any Error>
                    do {
                        let asset = try await limiter.withPermit {
                            try await self.prepare(key, epoch: request.accountEpoch)
                        }
                        result = .success(asset)
                    } catch {
                        result = .failure(error)
                    }
                    await self.complete(key, id: id, epoch: request.accountEpoch, result: result)
                }
                flights[key] = Flight(id: id, task: task, waiters: [waiterID: continuation])
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID, key: key) }
        }
    }

    func statistics() -> Statistics {
        Statistics(
            residentBytes: residentBytes, sourceCount: sources.count, thumbnailCount: thumbnails.count,
            pendingRequests: flights.count, sourceLoads: sourceLoads, thumbnailDecodes: thumbnailDecodes,
            mainThreadDecodes: decoder.mainThreadDecodeCount, cacheHits: cacheHits)
    }

    private func prepare(_ key: Key, epoch: UInt64) async throws -> ArtworkAsset {
        try Task.checkCancellation()
        try requireCurrent(epoch)
        let data = try await source(for: key.url, epoch: epoch)
        try Task.checkCancellation()
        try requireCurrent(epoch)
        thumbnailDecodes += 1
        let asset = try await decoder.decode(data, maximumPixelDimension: key.pixels)
        try Task.checkCancellation()
        try requireCurrent(epoch)
        return asset
    }

    private func source(for url: URL, epoch: UInt64) async throws -> Data {
        try requireCurrent(epoch)
        if var cached = sources[url] {
            cached.lastAccess = tick()
            sources[url] = cached
            return cached.value
        }
        if let flight = sourceFlights[url] { return try await flight.task.value }
        let id = UUID()
        sourceLoads += 1
        let task = Task { [loader] in try await loader.load(url) }
        sourceFlights[url] = SourceFlight(id: id, task: task)
        do {
            let data = try await task.value
            try requireCurrent(epoch)
            guard sourceFlights[url]?.id == id else { throw CancellationError() }
            sourceFlights[url] = nil
            if data.count <= maximumCacheBytes {
                sources[url] = Cached(value: data, bytes: data.count, lastAccess: tick())
                residentBytes += data.count
                trimCache()
            }
            return data
        } catch {
            if sourceFlights[url]?.id == id { sourceFlights[url] = nil }
            throw error
        }
    }

    private func complete(_ key: Key, id: UUID, epoch: UInt64, result: Result<ArtworkAsset, any Error>) {
        guard let flight = flights[key], flight.id == id else { return }
        flights[key] = nil
        guard activeEpoch == epoch else {
            flight.waiters.values.forEach { $0.resume(throwing: ArtworkFailure.retired) }
            return
        }
        if case let .success(asset) = result, asset.byteCount <= maximumCacheBytes {
            thumbnails[key] = Cached(value: asset, bytes: asset.byteCount, lastAccess: tick())
            residentBytes += asset.byteCount
            trimCache()
        }
        flight.waiters.values.forEach { $0.resume(with: result) }
    }

    private func cancelWaiter(_ id: UUID, key: Key) {
        guard var flight = flights[key], let continuation = flight.waiters.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CancellationError())
        if flight.waiters.isEmpty {
            flights[key] = nil
            flight.task.cancel()
        } else {
            flights[key] = flight
        }
    }

    private func clearOwnedBytes() {
        sources.removeAll(keepingCapacity: false)
        thumbnails.removeAll(keepingCapacity: false)
        residentBytes = 0
        let previous = flights.values
        flights.removeAll(keepingCapacity: false)
        for flight in previous {
            flight.task.cancel()
            flight.waiters.values.forEach { $0.resume(throwing: ArtworkFailure.retired) }
        }
        sourceFlights.values.forEach { $0.task.cancel() }
        sourceFlights.removeAll(keepingCapacity: false)
    }

    private func requireCurrent(_ epoch: UInt64) throws {
        guard activeEpoch == epoch else { throw ArtworkFailure.retired }
    }

    private func tick() -> UInt64 {
        accessCounter &+= 1
        return accessCounter
    }

    private func trimCache() {
        while residentBytes > maximumCacheBytes || sources.count + thumbnails.count > maximumCacheEntries {
            let source = sources.min { $0.value.lastAccess < $1.value.lastAccess }
            let thumbnail = thumbnails.min { $0.value.lastAccess < $1.value.lastAccess }
            if let source, thumbnail.map({ source.value.lastAccess < $0.value.lastAccess }) ?? true {
                residentBytes -= source.value.bytes
                sources[source.key] = nil
            } else if let thumbnail {
                residentBytes -= thumbnail.value.bytes
                thumbnails[thumbnail.key] = nil
            } else {
                break
            }
        }
    }

    private static func pixelBucket(_ requested: Int) -> Int {
        [64, 128, 256, 512, 1_024].first { $0 >= requested } ?? 1_024
    }
}

/// Capacity covers the entire fetch/decode operation so queued derivatives never retain source
/// buffers while waiting. Cancellation cannot release an active noncooperative decoder early.
private actor ArtworkWorkLimiter {
    private let maximumActive: Int
    private var active = 0
    private var queued: [(UUID, CheckedContinuation<Void, any Error>)] = []

    init(maximumActive: Int) {
        precondition(maximumActive > 0)
        self.maximumActive = maximumActive
    }

    func withPermit<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if active < maximumActive {
                active += 1
            } else {
                try await withCheckedThrowingContinuation { queued.append((id, $0)) }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        defer {
            if queued.isEmpty { active -= 1 } else { queued.removeFirst().1.resume() }
        }
        try Task.checkCancellation()
        return try await operation()
    }

    private func cancel(_ id: UUID) {
        guard let index = queued.firstIndex(where: { $0.0 == id }) else { return }
        queued.remove(at: index).1.resume(throwing: CancellationError())
    }
}
