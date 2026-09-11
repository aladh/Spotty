//
//  ClientTokenProvider.swift
//  Spotty
//
//  The Client-Token header both partner APIs require, alongside the bearer.
//

import Foundation
import SpottyDomain

/// A client token and how long it is good for.
nonisolated struct GrantedClientToken: Sendable, Equatable {
    var token: String
    var expiresAt: Date
}

nonisolated enum ClientTokenError: Error, LocalizedError, Equatable {
    case requestFailed(Int)
    case malformedResponse
    /// Spotify wants a proof-of-work answer before granting. Neither libspot nor go-librespot
    /// implements it, and a first-party client id has never been challenged in practice — so
    /// this is surfaced rather than silently retried, to make it visible if that ever changes.
    case challenged

    var errorDescription: String? {
        switch self {
        case let .requestFailed(status):
            "Could not obtain a Spotify client token (HTTP \(status))"
        case .malformedResponse:
            "The Spotify client token response could not be read"
        case .challenged:
            "Spotify asked for a client-token challenge that Spotty cannot answer"
        }
    }
}

/// Obtains and caches the `Client-Token` that `api-partner` and `spclient` require.
///
/// Unauthenticated: it identifies the *application*, not the user, so it is fetched with no
/// bearer and is independent of the keymaster grant. Both are needed together — the bearer
/// alone gets 401 from these hosts.
actor ClientTokenProvider {
    static let shared = ClientTokenProvider()

    /// Injected so the caching and expiry rules can be tested without a network.
    typealias Fetcher = @Sendable (_ deviceId: String) async throws -> GrantedClientToken

    private let fetcher: Fetcher
    private let deviceIdStore: DeviceIdStoring
    private var generation: UInt64 = 0
    private var cached: GrantedClientToken?
    private var inFlight: Task<GrantedClientToken, Error>?

    init(
        deviceIdStore: DeviceIdStoring = UserDefaultsDeviceIdStore(),
        fetcher: @escaping Fetcher = { try await ClientTokenRequest.send(deviceId: $0) },
    ) {
        self.deviceIdStore = deviceIdStore
        self.fetcher = fetcher
    }

    /// A valid client token, fetching one if there is none or the cached one has expired.
    func token(now: Date = Date()) async throws -> String {
        if let cached, cached.expiresAt > now {
            return cached.token
        }

        // A second caller during a fetch joins the one already running rather than asking
        // Spotify for a second token against the same device id.
        if let inFlight {
            return try await inFlight.value.token
        }

        let deviceId = deviceIdStore.deviceId()
        let startedAt = generation
        // Commit inside the shared task, before any joiner can expose the token to HTTP callers.
        let task = Task { try await self.fetchAndCommit(deviceId: deviceId, generation: startedAt) }
        inFlight = task
        defer { if inFlight == task { inFlight = nil } }
        return try await task.value.token
    }

    private func fetchAndCommit(deviceId: String, generation: UInt64) async throws -> GrantedClientToken {
        let granted = try await fetcher(deviceId)
        guard generation == self.generation else { throw CancellationError() }
        cached = granted
        inFlight = nil
        return granted
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
        generation &+= 1
        cached = nil
        inFlight?.cancel()
        inFlight = nil
    }
}

/// The request and response for `clienttoken.spotify.com/v1/clienttoken`.
///
/// Field numbers come from `spotify.clienttoken.http.v0` and `spotify.clienttoken.data.v0`,
/// as generated in the libspot checkout. They are hand-encoded rather than generated: the
/// whole request is four scalars, and the response only ever needs two fields out of it.
nonisolated enum ClientTokenRequest {
    static let endpoint = URL(string: "https://clienttoken.spotify.com/v1/clienttoken")!

    /// The application identity must match the desktop bearer used beside this token.
    ///
    /// Spotify still grants a token for `0.0.0`, but Pathfinder now refuses that token beside
    /// a desktop-client OAuth bearer with `403 Client/request not allowed`. This is the exact
    /// version advertised by Spotify's signed macOS client installed on 2026-08-18.
    static let clientVersion = "1.2.84.476.ga1ff6607"

    /// ```
    /// ClientTokenRequest {
    ///   1 request_type = REQUEST_CLIENT_DATA_REQUEST (1)
    ///   2 client_data {
    ///       1 client_version
    ///       2 client_id
    ///       3 connectivity_sdk_data {
    ///           1 platform_specific_data { 3 mac {} }
    ///           2 device_id
    ///         }
    ///     }
    /// }
    /// ```
    /// The macOS submessage is sent empty, exactly as libspot does — Spotify grants the token
    /// without any of its optional hardware fields.
    static func encode(clientId: String, deviceId: String) -> Data {
        var writer = ProtobufWriter()
        writer.varint(field: 1, 1)
        writer.message(field: 2) { clientData in
            clientData.string(field: 1, clientVersion)
            clientData.string(field: 2, clientId)
            clientData.message(field: 3) { sdk in
                sdk.message(field: 1) { platform in
                    platform.message(field: 3) { _ in }
                }
                sdk.string(field: 2, deviceId)
            }
        }
        return writer.data
    }

    /// ```
    /// ClientTokenResponse {
    ///   1 response_type   (1 = granted, 2 = challenges)
    ///   2 granted_token { 1 token, 2 expires_after_seconds }
    /// }
    /// ```
    static func decode(_ data: Data, now: Date = Date()) throws -> GrantedClientToken {
        guard let responseType = ProtobufReader.firstVarint(field: 1, in: data) else {
            throw ClientTokenError.malformedResponse
        }

        if responseType == 2 {
            throw ClientTokenError.challenged
        }

        guard responseType == 1,
            let granted = ProtobufReader.firstBytes(field: 2, in: data),
            let token = ProtobufReader.firstString(field: 1, in: granted),
            !token.isEmpty
        else {
            throw ClientTokenError.malformedResponse
        }

        // Spotify sends a fortnight or so; treat a missing value as an hour rather than as
        // never-expiring, so a surprise cannot pin a stale token forever.
        //
        // Converted in a closure, not as `.map(TimeInterval.init)`: that reference resolves to
        // `Double(bitPattern:)`, which reinterprets the seconds as the bits of a float. 1209600
        // becomes a denormal around 6e-318, which disappears entirely when added to a Date — so
        // every token expired the instant it was granted, and each request fetched a new one.
        let lifetime = ProtobufReader.firstVarint(field: 2, in: granted).map { TimeInterval($0) } ?? 3600

        return GrantedClientToken(token: token, expiresAt: now.addingTimeInterval(lifetime))
    }

    static func send(
        deviceId: String,
        transport: SpotifyCredentials.Transport = { try await URLSession.shared.data(for: $0) },
        retryTiming: SpotifyTransientRetry.Timing = .production
    ) async throws -> GrantedClientToken {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Accept")
        request.setValue(clientVersion, forHTTPHeaderField: "Spotify-App-Version")
        request.httpBody = encode(clientId: KeymasterAuth.clientId, deviceId: deviceId)

        debugLog("ClientToken", "[POST] \(endpoint.absoluteString)")

        let (data, response) = try await TokenRequestTransport.send(
            request, transport: transport, timing: retryTiming, retryNetworkErrors: true)

        guard let http = response as? HTTPURLResponse else {
            throw ClientTokenError.malformedResponse
        }
        guard http.statusCode == 200 else {
            throw ClientTokenError.requestFailed(http.statusCode)
        }

        return try decode(data)
    }
}
