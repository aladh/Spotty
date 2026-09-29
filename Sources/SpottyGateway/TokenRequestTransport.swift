import Foundation

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
                guard retryNetworkErrors,
                    try await SpotifyTransientRetry.wait(after: error, completedAttempts: attempts, timing: timing)
                else { throw error }
                continue
            }
            guard let http = result.1 as? HTTPURLResponse,
                // A revoked grant is terminal even if a proxy used a transient status.
                KeymasterAuth.tokenFailure(status: http.statusCode, body: result.0) != .grantRevoked,
                try await SpotifyTransientRetry.wait(
                    afterStatus: http.statusCode, retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After"),
                    completedAttempts: attempts, timing: timing)
            else { return result }
        }
    }
}
