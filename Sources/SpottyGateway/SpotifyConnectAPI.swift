import SpottyDomain
import Foundation
import SpottyRuntimeContracts

nonisolated enum SpotifyConnectAPIError: Error, LocalizedError, Equatable {
    case invalidTrackURI
    case malformedResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .invalidTrackURI:
            "Spotify returned an invalid track identifier"
        case .malformedResponse:
            "Spotify returned an unreadable response"
        case let .requestFailed(status):
            "Spotify rejected the command (HTTP \(status))"
        }
    }
}

private nonisolated struct SpotifyConnectTrackResponse: Decodable, Sendable {
    struct Artist: Decodable, Sendable { let name: String?; let gid: String? }
    struct Album: Decodable, Sendable {
        struct CoverGroup: Decodable, Sendable {
            struct Image: Decodable, Sendable {
                let fileID: String?
                let width: Int?
                let height: Int?

                enum CodingKeys: String, CodingKey {
                    case fileID = "file_id"
                    case width, height
                }
            }
            let image: [Image]?
        }
        let coverGroup: CoverGroup?
        let name: String?
        let gid: String?

        enum CodingKeys: String, CodingKey {
            case coverGroup = "cover_group"
            case name, gid
        }
    }

    let name: String?
    let artist: [Artist]?
    let album: Album?
    let duration: Int?
}

/// The small subset of spclient used for remote Connect commands and cold track metadata.
nonisolated struct SpotifyConnectAPI: Sendable {
    static let baseURL = URL(string: "https://spclient.wg.spotify.com/")!
    typealias Transport = SpotifyCredentials.Transport

    private let credentials: SpotifyCredentials

    init(
        accessToken: @escaping @Sendable () async throws -> String = {
            try await KeymasterSession.shared.accessToken()
        },
        clientToken: @escaping @Sendable () async throws -> String = {
            try await ClientTokenProvider.shared.token()
        },
        invalidateAccessToken: @escaping @Sendable (String) async throws -> Void = SpotifyCredentials
            .invalidateSharedAccess,
        invalidateClientToken: @escaping @Sendable (String) async -> Void = SpotifyCredentials.invalidateShared,
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) },
        retryTiming: SpotifyTransientRetry.Timing = .production
    ) {
        credentials = SpotifyCredentials(
            accessToken: accessToken,
            clientToken: clientToken,
            invalidateAccessToken: invalidateAccessToken,
            invalidateClientToken: invalidateClientToken,
            transport: transport,
            retryTiming: retryTiming
        )
    }

    func send(_ command: SpotifyConnectCommand, from sourceID: String, to targetID: String) async throws {
        let path = "connect-state/v1/player/command/from/\(sourceID)/to/\(targetID)"
        let body = try JSONEncoder().encode(SpotifyConnectCommandEnvelope(command: SpotifyConnectWireCommand(command)))
        let sent = try await credentials.retryingRefusedToken(
            replay: .unsafe,
            prepare: { try await makeRequest(method: "POST", url: Self.baseURL.appending(path: path), body: body) },
            send: transmit)
        try validate(sent.status)
    }

    func trackMetadata(for uri: String) async throws -> SpotifyConnectTrackMetadata {
        guard let id = Self.trackID(from: uri), let gid = SpotifyConnectGID.hex(fromBase62: id) else {
            throw SpotifyConnectAPIError.invalidTrackURI
        }

        let path = "metadata/4/track/\(gid)"
        let url = Self.baseURL
            .appending(path: path)
            .appending(queryItems: [URLQueryItem(name: "market", value: "from_token")])
        // URLSession is not a browser CORS client. The signed GET does not depend on an
        // unsigned OPTIONS preflight, and issuing one per track doubles cold queue traffic.
        let sent = try await credentials.retryingRefusedToken(
            replay: .safe,
            prepare: { try await makeRequest(method: "GET", url: url, body: nil) },
            send: transmit)
        try validate(sent.status)

        guard let response = try? JSONDecoder().decode(SpotifyConnectTrackResponse.self, from: sent.body),
            let title = response.name, !title.isEmpty
        else {
            throw SpotifyConnectAPIError.malformedResponse
        }

        let image = response.album?.coverGroup?.image?.max {
            ($0.width ?? $0.height ?? 0) < ($1.width ?? $1.height ?? 0)
        }
        let artworkURL = image?.fileID.flatMap { URL(string: "https://i.scdn.co/image/\($0)") }
        return SpotifyConnectTrackMetadata(
            uri: uri,
            title: title,
            artist: response.artist?.compactMap(\.name).joined(separator: ", ") ?? "Unknown artist",
            artworkURL: artworkURL,
            duration: TimeInterval(response.duration ?? 0) / 1_000,
            artists: (response.artist ?? []).compactMap { artist in
                guard let name = artist.name, let gid = artist.gid,
                    let id = SpotifyConnectGID.base62(fromHex: gid)
                else { return nil }
                let uri = "spotify:artist:\(id)"
                return CatalogItem(id: uri, uri: uri, title: name, subtitle: "Artist", artworkURL: nil, kind: .artist)
            },
            albumItem: response.album.flatMap { album in
                guard let name = album.name, !name.isEmpty, let gid = album.gid,
                    let id = SpotifyConnectGID.base62(fromHex: gid)
                else { return nil }
                let uri = "spotify:album:\(id)"
                return CatalogItem(
                    id: uri, uri: uri, title: name, subtitle: "Album", artworkURL: artworkURL, kind: .album)
            }
        )
    }

    private func makeRequest(method: String, url: URL, body: Data?) async throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        try await credentials.sign(&request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    private func transmit(_ request: URLRequest) async throws -> SpotifyCredentials.Attempt {
        let (data, response) = try await credentials.transport(request)
        guard let http = response as? HTTPURLResponse else {
            throw SpotifyConnectAPIError.malformedResponse
        }
        return SpotifyCredentials.Attempt(body: data, http: http, request: request)
    }

    private func validate(_ status: Int) throws {
        guard (200..<300).contains(status) else {
            throw SpotifyConnectAPIError.requestFailed(status)
        }
    }

    private static func trackID(from uri: String) -> String? {
        guard uri.hasPrefix("spotify:track:") else { return nil }
        let id = String(uri.dropFirst("spotify:track:".count))
        return id.isEmpty ? nil : id
    }
}

private nonisolated enum SpotifyConnectGID {
    private static let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

    static func base62(fromHex hex: String) -> String? {
        guard hex.count == 32 else { return nil }
        let chars = Array(hex)
        var bytes: [Int] = []
        for index in stride(from: 0, to: 32, by: 2) {
            guard let byte = UInt8(String(chars[index...index + 1]), radix: 16) else { return nil }
            bytes.append(Int(byte))
        }
        var result = ""
        repeat {
            var remainder = 0
            for index in bytes.indices {
                let value = remainder * 256 + bytes[index]
                bytes[index] = value / 62
                remainder = value % 62
            }
            result.insert(alphabet[remainder], at: result.startIndex)
        } while bytes.contains(where: { $0 != 0 })
        return String(repeating: "0", count: max(0, 22 - result.count)) + result
    }

    static func hex(fromBase62 id: String) -> String? {
        guard !id.isEmpty, id.count <= 22 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 16)
        for character in id {
            guard let digit = alphabet.firstIndex(of: character) else { return nil }
            var carry = digit
            for index in stride(from: bytes.count - 1, through: 0, by: -1) {
                let value = Int(bytes[index]) * 62 + carry
                bytes[index] = UInt8(value & 0xFF)
                carry = value >> 8
            }
            guard carry == 0 else { return nil }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
