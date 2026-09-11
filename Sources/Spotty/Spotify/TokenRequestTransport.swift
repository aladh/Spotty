import Foundation
import SpottyDomain

nonisolated enum TokenRequestTransport {
    static func send(
        _ request: URLRequest, transport: SpotifyCredentials.Transport,
        timing: SpotifyTransientRetry.Timing, retryNetworkErrors: Bool
    ) async throws -> (Data, URLResponse) {
        var attempts = 0
        while true {
            try Task.checkCancellation()
            attempts += 1
            let result: (Data, URLResponse)
            do {
                result = try await transport(request)
            } catch let error as URLError {
                guard retryNetworkErrors, attempts < SpotifyTransientRetry.maximumAttempts,
                    SpotifyTransientRetry.isRetryableURLError(error)
                else { throw error }
                try await timing.sleep(
                    SpotifyTransientRetry.backoffDelay(completedAttempts: attempts, unitJitter: timing.unitJitter()))
                continue
            }
            guard let http = result.1 as? HTTPURLResponse,
                // A revoked grant is terminal even if a proxy used a transient status.
                KeymasterAuth.tokenFailure(status: http.statusCode, body: result.0) != .grantRevoked,
                attempts < SpotifyTransientRetry.maximumAttempts,
                let delay = SpotifyTransientRetry.delay(
                    status: http.statusCode, retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After"),
                    completedAttempts: attempts, now: timing.now(), unitJitter: timing.unitJitter())
            else { return result }
            try await timing.sleep(delay)
        }
    }
}
