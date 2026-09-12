import Foundation
import SpottyRuntimeContracts
import SpottyDomain

/// The credentials every request to Spotify's own APIs carries, and the retry that keeps them
/// fresh.
///
/// `api-partner` and `spclient` are separate hosts with separate request shapes, but they are
/// authorized identically — a keymaster bearer identifying the user and a client token
/// identifying the application, both from the single grant this app now performs (see
/// `plans/single-grant-partner-api.md`) — and they refuse identically. Held in one place so the
/// 401 rule and the bounded transient-read retry are written once rather than per client.
nonisolated struct SpotifyCredentials: Sendable {
    /// Injected so request construction and decoding can be tested without a network.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// One attempt's outcome, naming the credentials it carried so a refusal can name them too.
    struct Attempt: Sendable {
        let body: Data
        let status: Int
        let accessToken: String?
        let clientToken: String?
        let retryAfter: String?

        init(
            body: Data,
            status: Int,
            accessToken: String?,
            clientToken: String?,
            retryAfter: String? = nil
        ) {
            self.body = body
            self.status = status
            self.accessToken = accessToken
            self.clientToken = clientToken
            self.retryAfter = retryAfter
        }

        init(body: Data, http: HTTPURLResponse, request: URLRequest) {
            self.init(
                body: body,
                status: http.statusCode,
                accessToken: SpotifyCredentials.accessTokenCarried(by: request),
                clientToken: request.value(forHTTPHeaderField: "Client-Token"),
                retryAfter: http.value(forHTTPHeaderField: "Retry-After")
            )
        }
    }

    /// The headers the desktop client sends. `App-Platform` and the xpui origin are not
    /// cosmetic — neither host is a public API, and the requests that work are the ones shaped
    /// like the client's own.
    static let appPlatform = "OSX_ARM64"
    static let origin = "https://xpui.app.spotify.com"

    /// Hoisted out of the default-argument lists that name it, where a closure literal is not
    /// isolation-checked: written inline, the hop onto `ClientTokenProvider` goes unnoticed and
    /// the `await` that expresses it is reported as unnecessary. The emitted code hops either
    /// way — the checking is what differs, and here the call is checked like any other.
    static let invalidateShared: @Sendable (String) async -> Void = {
        await ClientTokenProvider.shared.invalidate(rejected: $0)
    }

    static let invalidateSharedAccess: @Sendable (String) async throws -> Void = {
        _ = try await KeymasterSession.shared.refreshIgnoringExpiry(rejected: $0)
    }

    let accessToken: @Sendable () async throws -> String
    let clientToken: @Sendable () async throws -> String
    let invalidateAccessToken: @Sendable (String) async throws -> Void
    let invalidateClientToken: @Sendable (String) async -> Void
    let transport: Transport
    let retryTiming: SpotifyTransientRetry.Timing

    /// Signs a request as the desktop client: both credentials, and the headers naming which
    /// client is asking. Both, always — the bearer identifies the user, the client token the
    /// application, and these hosts want to see both.
    func sign(_ request: inout URLRequest) async throws {
        request.setValue(Self.appPlatform, forHTTPHeaderField: "App-Platform")
        request.setValue(Self.origin, forHTTPHeaderField: "Origin")
        request.setValue(Self.origin, forHTTPHeaderField: "Referer")
        request.setValue(ClientTokenRequest.clientVersion, forHTTPHeaderField: "Spotify-App-Version")
        request.setValue(
            "Spotify/\(ClientTokenRequest.clientVersion) macOS/\(ProcessInfo.processInfo.operatingSystemVersionString)",
            forHTTPHeaderField: "User-Agent"
        )
        try await request.setValue("Bearer \(accessToken())", forHTTPHeaderField: "Authorization")
        try await request.setValue(clientToken(), forHTTPHeaderField: "Client-Token")
    }

    /// Runs the attempt under the shared 401 and, for `.safe` reads, transient-retry policy.
    ///
    /// A 401 can be either credential. The client token is cached for the fortnight Spotify
    /// says it is good for; the bearer is cached until five minutes before expiry. Either can
    /// be revoked mid-validity, and retrying without naming the sent values would keep sending
    /// the same dead pair. Invalidating the exact sent pair is independent of retry permission:
    /// a second 401 or a budget-final 401 still drops those credentials, then returns so this
    /// cannot loop. The one named 401 replay counts toward
    /// `SpotifyTransientRetry.maximumAttempts` and happens at most once.
    ///
    /// The tokens the request actually carried are named, not just "the current ones" —
    /// concurrent requests share a pair, so one dead pair is refused several times over and the
    /// later refusals would otherwise discard the replacements the first one fetched.
    ///
    /// `.unsafe` writes keep a single transport attempt plus that 401 retry: a lost 5xx or
    /// timeout response after Spotify applied a mutation must not be replayed.
    func retryingRefusedToken(
        replay: SpotifyTransientRetry.Replay = .unsafe,
        _ attempt: () async throws -> Attempt,
    ) async throws -> (body: Data, status: Int) {
        try await Self.retryingRefusedCredentials(
            replay: replay,
            retryTiming: retryTiming,
            invalidateAccessToken: invalidateAccessToken,
            invalidateClientToken: invalidateClientToken,
            attempt
        )
    }

    /// Bearer-only variant for hosts that do not carry a client token.
    static func retryingRefusedCredentials(
        replay: SpotifyTransientRetry.Replay = .unsafe,
        retryTiming: SpotifyTransientRetry.Timing = .production,
        invalidateAccessToken: @Sendable (String) async throws -> Void,
        invalidateClientToken: (@Sendable (String) async -> Void)? = nil,
        _ attempt: () async throws -> Attempt,
    ) async throws -> (body: Data, status: Int) {
        var didInvalidateCredentials = false
        var completedAttempts = 0

        while true {
            try Task.checkCancellation()
            completedAttempts += 1

            do {
                let sent = try await attempt()
                if sent.status == 401 {
                    // Client-token drop is non-throwing. Do it first so a throwing bearer refresh
                    // (grantRevoked, noGrant, or a superseded spend) cannot leave a dead client cached
                    // for the rest of its fortnight. The exact sent pair is named even when this
                    // 401 will not be retried — a budget-final or already-replayed 401 must still
                    // make that rejection authoritative.
                    if let rejected = sent.clientToken {
                        await invalidateClientToken?(rejected)
                    }
                    if let rejected = sent.accessToken {
                        try await invalidateAccessToken(rejected)
                    }
                    if didInvalidateCredentials || completedAttempts >= SpotifyTransientRetry.maximumAttempts {
                        return (sent.body, sent.status)
                    }
                    didInvalidateCredentials = true
                    continue
                }

                if replay == .safe,
                    completedAttempts < SpotifyTransientRetry.maximumAttempts,
                    let delay = SpotifyTransientRetry.delay(
                        status: sent.status,
                        retryAfterHeader: sent.retryAfter,
                        completedAttempts: completedAttempts,
                        now: retryTiming.now(),
                        unitJitter: retryTiming.unitJitter()
                    )
                {
                    try await retryTiming.sleep(delay)
                    continue
                }

                return (sent.body, sent.status)
            } catch let error as CancellationError {
                throw error
            } catch let error as URLError {
                if replay == .safe,
                    completedAttempts < SpotifyTransientRetry.maximumAttempts,
                    SpotifyTransientRetry.isRetryableURLError(error)
                {
                    let delay = SpotifyTransientRetry.backoffDelay(
                        completedAttempts: completedAttempts,
                        unitJitter: retryTiming.unitJitter()
                    )
                    try await retryTiming.sleep(delay)
                    continue
                }
                throw error
            }
        }
    }

    /// The access token a signed request actually put on the wire, without the `Bearer ` prefix.
    static func accessTokenCarried(by request: URLRequest) -> String? {
        guard let authorization = request.value(forHTTPHeaderField: "Authorization"),
            authorization.hasPrefix("Bearer ")
        else { return nil }
        let token = String(authorization.dropFirst("Bearer ".count))
        return token.isEmpty ? nil : token
    }
}
