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

    #if DEBUG
        /// Actual existing work handles let lifetime tests join abandoned work without retaining its owner.
        enum WorkReceipt: Sendable {
            case thumbnail(Task<Void, Never>)
            case source(Task<Data, any Error>)
            case loaderCleanup(Task<Void, Never>)
            case cancellation(Task<Void, Never>)

            func cancel() {
                switch self {
                case let .source(task): task.cancel()
                case let .thumbnail(task), let .loaderCleanup(task), let .cancellation(task): task.cancel()
                }
            }

            func wait() async {
                switch self {
                case let .source(task): _ = await task.result
                case let .thumbnail(task), let .loaderCleanup(task), let .cancellation(task): await task.value
                }
            }
        }

        private var workObserver: (@Sendable (WorkReceipt) -> Void)?

        func observeWork(_ observer: @escaping @Sendable (WorkReceipt) -> Void) async {
            workObserver = observer
            await limiter.observeCancellation { observer(.cancellation($0)) }
        }
    #endif

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
    private struct LoaderCleanup {
        let id: UUID
        let task: Task<Void, Never>
    }

    private enum SourceInput: Sendable {
        case cached(Data)
        case loading(Task<Data, any Error>)

        func value() async throws -> Data {
            switch self {
            case let .cached(data): return data
            case let .loading(task): return try await task.value
            }
        }
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
    private var loaderCleanup: LoaderCleanup?
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

    deinit {
        for flight in flights.values {
            flight.task.cancel()
            flight.waiters.values.forEach { $0.resume(throwing: CancellationError()) }
        }
        sourceFlights.values.forEach { $0.task.cancel() }
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
        // A newer account can activate while cleanup is suspended. Record and serialize the
        // loader boundary before yielding; replacement sources await it outside this actor.
        let id = UUID()
        let cleanup = Task { [loader, previous = loaderCleanup?.task] in
            await previous?.value
            await loader.cancelAll()
        }
        #if DEBUG
            workObserver?(.loaderCleanup(cleanup))
        #endif
        loaderCleanup = LoaderCleanup(id: id, task: cleanup)
        await cleanup.value
        if loaderCleanup?.id == id { loaderCleanup = nil }
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
        #if DEBUG
            let cancellationObserver = workObserver
        #endif
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
                let worker = ThumbnailWorker(
                    owner: self, key: key, flightID: id, epoch: request.accountEpoch, limiter: limiter, decoder: decoder
                )
                let task = Task { await worker.run() }
                #if DEBUG
                    workObserver?(.thumbnail(task))
                #endif
                flights[key] = Flight(id: id, task: task, waiters: [waiterID: continuation])
            }
        } onCancel: {
            let task = Task { await self.cancelWaiter(waiterID, key: key) }
            #if DEBUG
                cancellationObserver?(.cancellation(task))
            #else
                _ = task
            #endif
        }
    }

    func statistics() -> Statistics {
        Statistics(
            residentBytes: residentBytes, sourceCount: sources.count, thumbnailCount: thumbnails.count,
            pendingRequests: flights.count, sourceLoads: sourceLoads, thumbnailDecodes: thumbnailDecodes,
            mainThreadDecodes: decoder.mainThreadDecodeCount, cacheHits: cacheHits)
    }

    private struct ThumbnailWorker: Sendable {
        weak var owner: ArtworkPipeline?
        let key: Key
        let flightID: UUID
        let epoch: UInt64
        let limiter: ArtworkWorkLimiter
        let decoder: ArtworkDecoder

        func run() async {
            let result: Result<ArtworkAsset, any Error>
            do {
                let asset = try await limiter.withPermit {
                    guard let input = try await owner?.sourceInput(key, flightID: flightID, epoch: epoch) else {
                        throw CancellationError()
                    }
                    // Capacity remains occupied until the real source/decode returns, even if
                    // callers cancel. Neither wait retains the pipeline or its cached bytes.
                    let data = try await input.value()
                    guard try await owner?.admitDecode(key, flightID: flightID, epoch: epoch) == true else {
                        throw CancellationError()
                    }
                    let asset = try await decoder.decode(data, maximumPixelDimension: key.pixels)
                    try Task.checkCancellation()
                    return asset
                }
                result = .success(asset)
            } catch {
                result = .failure(error)
            }
            await owner?.complete(key, id: flightID, epoch: epoch, result: result)
        }
    }

    private func requireFlight(_ key: Key, flightID: UUID, epoch: UInt64) throws {
        try Task.checkCancellation()
        try requireCurrent(epoch)
        guard flights[key]?.id == flightID else { throw CancellationError() }
    }

    private func admitDecode(_ key: Key, flightID: UUID, epoch: UInt64) throws -> Bool {
        try requireFlight(key, flightID: flightID, epoch: epoch)
        thumbnailDecodes += 1
        return true
    }

    private func sourceInput(_ key: Key, flightID: UUID, epoch: UInt64) throws -> SourceInput {
        try requireFlight(key, flightID: flightID, epoch: epoch)
        let url = key.url
        if var cached = sources[url] {
            cached.lastAccess = tick()
            sources[url] = cached
            return .cached(cached.value)
        }
        if let flight = sourceFlights[url] { return .loading(flight.task) }
        let id = UUID()
        sourceLoads += 1
        let task = Task { [weak self, loader, cleanup = loaderCleanup?.task] in
            let result: Result<Data, any Error>
            do {
                await cleanup?.value
                guard await self?.admitsSource(url, id: id, epoch: epoch) == true else { throw CancellationError() }
                result = .success(try await loader.load(url))
            } catch {
                result = .failure(error)
            }
            await self?.finishSource(url, id: id, epoch: epoch, result: result)
            return try result.get()
        }
        #if DEBUG
            workObserver?(.source(task))
        #endif
        sourceFlights[url] = SourceFlight(id: id, task: task)
        return .loading(task)
    }

    private func admitsSource(_ url: URL, id: UUID, epoch: UInt64) -> Bool {
        !Task.isCancelled && activeEpoch == epoch && sourceFlights[url]?.id == id
    }

    private func finishSource(_ url: URL, id: UUID, epoch: UInt64, result: Result<Data, any Error>) {
        guard sourceFlights[url]?.id == id else { return }
        sourceFlights[url] = nil
        guard !Task.isCancelled, activeEpoch == epoch else { return }
        if case let .success(data) = result, data.count <= maximumCacheBytes {
            sources[url] = Cached(value: data, bytes: data.count, lastAccess: tick())
            residentBytes += data.count
            trimCache()
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
            // A size variant can leave while another still needs the same source. Once the
            // last variant leaves, propagate cancellation to the otherwise unstructured fetch.
            if !flights.keys.contains(where: { $0.url == key.url }) {
                sourceFlights.removeValue(forKey: key.url)?.task.cancel()
            }
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
    #if DEBUG
        private var cancellationObserver: (@Sendable (Task<Void, Never>) -> Void)?

        func observeCancellation(_ observer: @escaping @Sendable (Task<Void, Never>) -> Void) {
            cancellationObserver = observer
        }
    #endif

    init(maximumActive: Int) {
        precondition(maximumActive > 0)
        self.maximumActive = maximumActive
    }

    func withPermit<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let id = UUID()
        #if DEBUG
            let observer = cancellationObserver
        #endif
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if active < maximumActive {
                active += 1
            } else {
                try await withCheckedThrowingContinuation { queued.append((id, $0)) }
            }
        } onCancel: {
            let task = Task { await self.cancel(id) }
            #if DEBUG
                observer?(task)
            #else
                _ = task
            #endif
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
