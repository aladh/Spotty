import Foundation
import SpottyRuntimeContracts

/// Obtains and caches the `Client-Token` that `api-partner` and `spclient` require.
///
/// Unauthenticated: it identifies the *application*, not the user, so it is fetched with no
/// bearer and is independent of the keymaster grant. Both are needed together — the bearer
/// alone gets 401 from these hosts.
actor ClientTokenProvider {
    static let shared = ClientTokenProvider()

    /// Injected so the caching and expiry rules can be tested without a network.
    typealias Fetcher = @Sendable (_ deviceId: String) async throws -> GrantedClientToken

    private struct Flight {
        let id: UInt64
        let task: Task<Void, Never>
        var waiters: [UInt64: CheckedContinuation<String, any Error>]

        func cancel() {
            task.cancel()
            for waiter in waiters.values { waiter.resume(throwing: CancellationError()) }
        }
    }

    private let fetcher: Fetcher
    private let deviceIdStore: DeviceIdStoring
    private var nextID: UInt64 = 0
    private var cached: GrantedClientToken?
    private var inFlight: Flight?

    init(
        deviceIdStore: DeviceIdStoring = UserDefaultsDeviceIdStore(),
        fetcher: @escaping Fetcher = { try await ClientTokenRequest.send(deviceId: $0) },
    ) {
        self.deviceIdStore = deviceIdStore
        self.fetcher = fetcher
    }

    deinit { inFlight?.cancel() }

    /// A valid client token, fetching one if there is none or the cached one has expired.
    /// Callers settle independently; the final cancellation retires their shared fetch.
    func token(now: Date = Date()) async throws -> String {
        try Task.checkCancellation()
        if let cached, cached.expiresAt > now {
            return cached.token
        }

        nextID &+= 1
        let consumerID = nextID
        let value: String = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if inFlight != nil {
                    inFlight?.waiters[consumerID] = continuation
                } else {
                    let deviceId = deviceIdStore.deviceId()
                    let task = Task { [weak self, fetcher] in
                        let result: Result<GrantedClientToken, any Error>
                        do {
                            try Task.checkCancellation()
                            result = .success(try await fetcher(deviceId))
                        } catch {
                            result = .failure(error)
                        }
                        await self?.finish(result, flightID: consumerID)
                    }
                    inFlight = Flight(id: consumerID, task: task, waiters: [consumerID: continuation])
                }
            }
        } onCancel: {
            Task { await self.cancel(consumerID) }
        }
        try Task.checkCancellation()
        return value
    }

    private func cancel(_ consumerID: UInt64) {
        guard let waiter = inFlight?.waiters.removeValue(forKey: consumerID) else { return }
        if inFlight?.waiters.isEmpty == true {
            let retired = inFlight
            inFlight = nil
            retired?.task.cancel()
        }
        waiter.resume(throwing: CancellationError())
    }

    private func finish(_ result: Result<GrantedClientToken, any Error>, flightID: UInt64) {
        guard let flight = inFlight, flight.id == flightID else { return }
        inFlight = nil
        // Commit before any caller can expose the token to HTTP requests or invalidate it.
        if case .success(let granted) = result { cached = granted }
        let token = result.map { $0.token }
        for waiter in flight.waiters.values { waiter.resume(with: token) }
    }

    /// Drops the cached token, so the next caller fetches a fresh one. For a 401, where the
    /// token is dead before its stated expiry.
    ///
    /// **Only if `rejected` is still the cached one.** Requests run concurrently, so one dead
    /// token is refused several times over, and each refusal arrives separately — the later
    /// ones after the first has already fetched a replacement. Dropping unconditionally there
    /// throws that replacement away and costs a handshake per refused request, against an
    /// endpoint that can answer with a proof-of-work challenge this app cannot solve.
    func invalidate(rejected: String) {
        guard cached?.token == rejected else { return }
        cached = nil
        let retired = inFlight
        inFlight = nil
        retired?.cancel()
    }
}
