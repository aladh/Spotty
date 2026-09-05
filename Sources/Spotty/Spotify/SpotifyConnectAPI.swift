import SpottyDomain
import Foundation

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

/// A command sent directly to the device that currently owns Spotify Connect playback.
nonisolated struct SpotifyConnectCommand: Encodable, Sendable {
    enum Kind: String, Encodable, Sendable {
        case pause
        case resume
        case next = "skip_next"
        case previous = "skip_prev"
        case seek = "seek_to"
        case shuffle = "set_shuffling_context"
        case repeatContext = "set_repeating_context"
        case repeatTrack = "set_repeating_track"
        case addToQueue = "add_to_queue"
        case setQueue = "set_queue"
        case play
    }

    enum Value: Encodable, Sendable {
        case integer(Int)
        case boolean(Bool)

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case let .integer(value): try container.encode(value)
            case let .boolean(value): try container.encode(value)
            }
        }
    }

    struct Context: Encodable, Sendable {
        struct Track: Encodable, Sendable { let uri: String }
        struct Page: Encodable, Sendable { let tracks: [Track] }
        struct SkipTo: Encodable, Sendable {
            var trackURI: String?
            var trackIndex: Int?

            enum CodingKeys: String, CodingKey {
                case trackURI = "track_uri"
                case trackIndex = "track_index"
            }
        }
        struct Options: Encodable, Sendable {
            let skipTo: SkipTo

            enum CodingKeys: String, CodingKey { case skipTo = "skip_to" }
        }

        let uri: String
        let url: String
        var pages: [Page]?
        let options: Options?

        init(uri: String, trackIndex: Int? = nil) {
            self.uri = uri
            url = "context://\(uri)"
            pages = nil
            if uri.hasPrefix("spotify:track:") {
                options = Options(skipTo: SkipTo(trackURI: uri))
            } else if let trackIndex, trackIndex >= 0 {
                options = Options(skipTo: SkipTo(trackIndex: trackIndex))
            } else {
                options = nil
            }
        }

        init(trackURIs: [String]) {
            uri = ""
            url = ""
            pages = [Page(tracks: trackURIs.map(Track.init(uri:)))]
            options = nil
        }
    }

    struct LoggingParameters: Encodable, Sendable {
        let commandID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

        enum CodingKeys: String, CodingKey { case commandID = "command_id" }
    }

    struct Track: Encodable, Sendable {
        let uri: String
        let uid = ""
        let metadata: [String: String] = [:]
    }

    struct QueueTrack: Encodable, Sendable {
        let uri: String
        let uid: String
        let provider: String
        let metadata: [String: String]
        let removed: [String]
        let blocked: [String]
        let restrictions: [String: [String]]
        let albumURI: String
        let disallowReasons: [String]
        let artistURI: String

        init(_ track: QueueProtocolTrack) {
            uri = track.uri
            uid = track.uid
            provider = track.provider
            metadata = track.metadata
            removed = track.removed
            blocked = track.blocked
            restrictions = track.restrictions
            albumURI = track.albumURI
            disallowReasons = track.disallowReasons
            artistURI = track.artistURI
        }

        enum CodingKeys: String, CodingKey {
            case uri, uid, provider, metadata, removed, blocked, restrictions
            case albumURI = "album_uri"
            case disallowReasons = "disallow_reasons"
            case artistURI = "artist_uri"
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(uri, forKey: .uri)
            try container.encode(uid, forKey: .uid)
            try container.encode(provider, forKey: .provider)
            try container.encode(metadata, forKey: .metadata)
            if !removed.isEmpty { try container.encode(removed, forKey: .removed) }
            if !blocked.isEmpty { try container.encode(blocked, forKey: .blocked) }
            if !restrictions.isEmpty { try container.encode(restrictions, forKey: .restrictions) }
            if !albumURI.isEmpty { try container.encode(albumURI, forKey: .albumURI) }
            if !disallowReasons.isEmpty { try container.encode(disallowReasons, forKey: .disallowReasons) }
            if !artistURI.isEmpty { try container.encode(artistURI, forKey: .artistURI) }
        }
    }

    let endpoint: Kind
    let loggingParameters = LoggingParameters()
    var value: Value?
    var context: Context?
    var track: Track?
    var nextTracks: [QueueTrack]?
    var prevTracks: [QueueTrack]?
    var queueRevision: String?

    enum CodingKeys: String, CodingKey {
        case endpoint
        case loggingParameters = "logging_params"
        case value
        case context
        case track
        case nextTracks = "next_tracks"
        case prevTracks = "prev_tracks"
        case queueRevision = "queue_revision"
        case options
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(endpoint, forKey: .endpoint)
        try container.encode(loggingParameters, forKey: .loggingParameters)
        try container.encodeIfPresent(value, forKey: .value)
        try container.encodeIfPresent(track, forKey: .track)
        try container.encodeIfPresent(nextTracks, forKey: .nextTracks)
        try container.encodeIfPresent(prevTracks, forKey: .prevTracks)
        try container.encodeIfPresent(queueRevision, forKey: .queueRevision)
        if let context {
            try container.encode(context, forKey: .context)
            try container.encodeIfPresent(context.options, forKey: .options)
        }
    }

    static let pause = SpotifyConnectCommand(endpoint: .pause)
    static let resume = SpotifyConnectCommand(endpoint: .resume)
    static let next = SpotifyConnectCommand(endpoint: .next)
    static let previous = SpotifyConnectCommand(endpoint: .previous)

    static func seek(to milliseconds: Int) -> Self {
        SpotifyConnectCommand(endpoint: .seek, value: .integer(max(0, milliseconds)))
    }

    static func shuffle(_ enabled: Bool) -> Self {
        SpotifyConnectCommand(endpoint: .shuffle, value: .boolean(enabled))
    }

    static func repeatContext(_ enabled: Bool) -> Self {
        SpotifyConnectCommand(endpoint: .repeatContext, value: .boolean(enabled))
    }

    static func repeatTrack(_ enabled: Bool) -> Self {
        SpotifyConnectCommand(endpoint: .repeatTrack, value: .boolean(enabled))
    }

    static func repeatMutation(_ mutation: RepeatFlagMutation) -> Self {
        switch mutation.flag {
        case .context: repeatContext(mutation.enabled)
        case .track: repeatTrack(mutation.enabled)
        }
    }

    static func addToQueue(_ uri: String) -> Self {
        SpotifyConnectCommand(endpoint: .addToQueue, track: Track(uri: uri))
    }

    static func setQueue(
        next: [QueueProtocolTrack],
        prev: [QueueProtocolTrack],
        queueRevision: String
    ) -> Self {
        var command = SpotifyConnectCommand(endpoint: .setQueue)
        command.nextTracks = next.map(QueueTrack.init)
        command.prevTracks = prev.map(QueueTrack.init)
        command.queueRevision = queueRevision
        return command
    }

    static func play(uri: String, trackIndex: Int? = nil) -> Self {
        SpotifyConnectCommand(endpoint: .play, context: Context(uri: uri, trackIndex: trackIndex))
    }

    static func play(trackURIs: [String]) -> Self {
        SpotifyConnectCommand(endpoint: .play, context: Context(trackURIs: trackURIs))
    }
}

private nonisolated struct SpotifyConnectCommandEnvelope: Encodable, Sendable {
    let command: SpotifyConnectCommand
    let connectionType = "wlan"
    let intentID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

    enum CodingKeys: String, CodingKey {
        case command
        case connectionType = "connection_type"
        case intentID = "intent_id"
    }
}

nonisolated struct SpotifyConnectTrackMetadata: Sendable {
    let uri: String
    let title: String
    let artist: String
    let artworkURL: URL?
    let duration: TimeInterval
    var artists: [CatalogItem] = []
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

        enum CodingKeys: String, CodingKey { case coverGroup = "cover_group" }
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
        let body = try JSONEncoder().encode(SpotifyConnectCommandEnvelope(command: command))
        let sent = try await credentials.retryingRefusedToken(replay: .unsafe) {
            try await request(method: "POST", path: path, body: body)
        }
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
        let sent = try await credentials.retryingRefusedToken(replay: .safe) {
            try await request(method: "GET", url: url, body: nil)
        }
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
            }
        )
    }

    private func request(method: String, path: String, body: Data?) async throws -> SpotifyCredentials.Attempt {
        try await request(method: method, url: Self.baseURL.appending(path: path), body: body)
    }

    private func request(method: String, url: URL, body: Data?) async throws -> SpotifyCredentials.Attempt {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        try await credentials.sign(&request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }

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
