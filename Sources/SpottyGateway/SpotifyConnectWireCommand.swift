import Foundation
import SpottyDomain
import SpottyRuntimeContracts

/// Encodes runtime intent without maintaining a second command model or command factories.
/// Spotify's field names and logging identifiers stay inside the gateway.
nonisolated struct SpotifyConnectWireCommand: Encodable, Sendable {
    private let command: SpotifyConnectCommand
    private let loggingParameters = LoggingParameters()

    init(_ command: SpotifyConnectCommand) {
        self.command = command
    }

    private enum CodingKeys: String, CodingKey {
        case endpoint, value, context, track, options
        case loggingParameters = "logging_params"
        case nextTracks = "next_tracks"
        case prevTracks = "prev_tracks"
        case queueRevision = "queue_revision"
    }

    private var endpoint: String {
        switch command.endpoint {
        case .pause: "pause"
        case .resume: "resume"
        case .next: "skip_next"
        case .previous: "skip_prev"
        case .seek: "seek_to"
        case .shuffle: "set_shuffling_context"
        case .repeatContext: "set_repeating_context"
        case .repeatTrack: "set_repeating_track"
        case .addToQueue: "add_to_queue"
        case .setQueue: "set_queue"
        case .play: "play"
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(endpoint, forKey: .endpoint)
        try container.encode(loggingParameters, forKey: .loggingParameters)
        switch command.value {
        case let .integer(value): try container.encode(value, forKey: .value)
        case let .boolean(value): try container.encode(value, forKey: .value)
        case nil: break
        }
        try container.encodeIfPresent(command.track.map { Track(uri: $0.uri) }, forKey: .track)
        try container.encodeIfPresent(command.nextTracks?.map(QueueTrack.init), forKey: .nextTracks)
        try container.encodeIfPresent(command.prevTracks?.map(QueueTrack.init), forKey: .prevTracks)
        try container.encodeIfPresent(command.queueRevision, forKey: .queueRevision)
        if let context = command.context.map(Context.init) {
            try container.encode(context, forKey: .context)
            // Preserve selection options at both locations in the Connect payload.
            try container.encodeIfPresent(context.options, forKey: .options)
        }
    }

    private struct LoggingParameters: Encodable, Sendable {
        let commandID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

        enum CodingKeys: String, CodingKey { case commandID = "command_id" }
    }

    private struct Track: Encodable, Sendable {
        let uri: String
        let uid = ""
        let metadata: [String: String] = [:]
    }

    private struct Context: Encodable, Sendable {
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
        let pages: [Page]?
        let options: Options?

        init(_ context: SpotifyConnectCommand.Context) {
            if let trackURIs = context.trackURIs {
                uri = ""
                url = ""
                pages = [Page(tracks: trackURIs.map(Track.init))]
                options = nil
            } else {
                uri = context.uri
                url = "context://\(uri)"
                pages = nil
                if uri.hasPrefix("spotify:track:") {
                    options = Options(skipTo: SkipTo(trackURI: uri))
                } else if let index = context.trackIndex, index >= 0 {
                    options = Options(skipTo: SkipTo(trackIndex: index))
                } else {
                    options = nil
                }
            }
        }
    }

    private struct QueueTrack: Encodable, Sendable {
        let track: QueueProtocolTrack

        enum CodingKeys: String, CodingKey {
            case uri, uid, provider, metadata, removed, blocked, restrictions
            case albumURI = "album_uri"
            case disallowReasons = "disallow_reasons"
            case artistURI = "artist_uri"
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(track.uri, forKey: .uri)
            try container.encode(track.uid, forKey: .uid)
            try container.encode(track.provider, forKey: .provider)
            try container.encode(track.metadata, forKey: .metadata)
            if !track.removed.isEmpty { try container.encode(track.removed, forKey: .removed) }
            if !track.blocked.isEmpty { try container.encode(track.blocked, forKey: .blocked) }
            if !track.restrictions.isEmpty { try container.encode(track.restrictions, forKey: .restrictions) }
            if !track.albumURI.isEmpty { try container.encode(track.albumURI, forKey: .albumURI) }
            if !track.disallowReasons.isEmpty { try container.encode(track.disallowReasons, forKey: .disallowReasons) }
            if !track.artistURI.isEmpty { try container.encode(track.artistURI, forKey: .artistURI) }
        }
    }
}

nonisolated struct SpotifyConnectCommandEnvelope: Encodable, Sendable {
    let command: SpotifyConnectWireCommand
    let connectionType = "wlan"
    let intentID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

    enum CodingKeys: String, CodingKey {
        case command
        case connectionType = "connection_type"
        case intentID = "intent_id"
    }
}
