import SpottyRuntimeContracts

/// Shares fetches and a bounded account cache between Now Playing and queue hydration.
/// Each caller settles independently; neither cancellation nor reset waits for remote cooperation.
actor TrackMetadataService {
    private struct InFlightRequest {
        let id: UInt64
        let task: Task<Void, Never>
        var waiters: [UInt64: CheckedContinuation<SpotifyConnectTrackMetadata, any Error>]

        func cancel() {
            task.cancel()
            for waiter in waiters.values { waiter.resume(throwing: CancellationError()) }
        }
    }

    private static let cacheLimit = 512
    private let remote: any RemotePlaybackClient
    private var cache: [String: SpotifyConnectTrackMetadata] = [:]
    private var nextID: UInt64 = 0
    private var inFlight: [String: InFlightRequest] = [:]

    init(remote: any RemotePlaybackClient) {
        self.remote = remote
    }

    deinit {
        for request in inFlight.values { request.cancel() }
    }

    func metadata(for uri: String) async throws -> SpotifyConnectTrackMetadata {
        try Task.checkCancellation()
        if let cached = cache[uri] { return cached }
        nextID &+= 1
        let consumerID = nextID
        let value: SpotifyConnectTrackMetadata = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if inFlight[uri] != nil {
                    inFlight[uri]?.waiters[consumerID] = continuation
                } else {
                    let task = Task { [weak self, remote] in
                        let result: Result<SpotifyConnectTrackMetadata, any Error>
                        do {
                            result = .success(try await remote.trackMetadata(for: uri))
                        } catch {
                            result = .failure(error)
                        }
                        await self?.finish(result, uri: uri, requestID: consumerID)
                    }
                    inFlight[uri] = InFlightRequest(
                        id: consumerID, task: task, waiters: [consumerID: continuation])
                }
            }
        } onCancel: {
            Task { await self.cancel(consumerID, uri: uri) }
        }
        try Task.checkCancellation()
        return value
    }

    func reset() {
        let retired = inFlight
        inFlight.removeAll(keepingCapacity: false)
        cache.removeAll(keepingCapacity: false)
        for request in retired.values { request.cancel() }
    }

    private func cancel(_ consumerID: UInt64, uri: String) {
        guard let waiter = inFlight[uri]?.waiters.removeValue(forKey: consumerID) else { return }
        if inFlight[uri]?.waiters.isEmpty == true {
            let retired = inFlight.removeValue(forKey: uri)
            retired?.task.cancel()
        }
        waiter.resume(throwing: CancellationError())
    }

    private func finish(
        _ result: Result<SpotifyConnectTrackMetadata, any Error>, uri: String, requestID: UInt64
    ) {
        guard inFlight[uri]?.id == requestID,
            let request = inFlight.removeValue(forKey: uri)
        else { return }
        if case .success(let value) = result {
            cache[uri] = value
            trimCache(preserving: uri)
        }
        for waiter in request.waiters.values { waiter.resume(with: result) }
    }

    private func trimCache(preserving uri: String) {
        // One insertion exceeds the bound by at most one entry. Release the keys iterator before
        // mutating; otherwise its retained dictionary forces a copy of the whole cache per eviction.
        guard cache.count > Self.cacheLimit,
            let victim = cache.keys.first(where: { $0 != uri })
        else { return }
        cache[victim] = nil
    }
}
