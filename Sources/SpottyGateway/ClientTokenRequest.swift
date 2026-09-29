import Foundation
import SpottyDiagnostics

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
