import SpottyDiagnostics
//
//  TrackAttributes.swift
//  Spotty
//
//  Per-track enrichment — popularity, tempo, and musical key — from Spotify's
//  private batched extended-metadata API at spclient.
//

import Foundation
import SpottyRuntimeContracts
import SpottyDomain

/// The batched extended-metadata endpoint the desktop client uses for its BPM
/// and Key columns.
///
/// One POST carries every track: each `EntityRequest` names a track uri and asks
/// for two extensions — the full v4 track message (`TRACK_V4`, which carries
/// popularity) and `AUDIO_ATTRIBUTES_V2` (tempo and key).
nonisolated struct TrackAttributesAPI: Sendable {
    static let endpoint = URL(string: "https://spclient.wg.spotify.com/extended-metadata/v0/extended-metadata")!

    /// Extension kind answering with the full track message (popularity included).
    static let trackKind: UInt64 = 10
    /// Extension kind answering with tempo and musical key. The pinned desktop
    /// proto predates this entry, so it is named by value like the client does.
    static let audioAttributesKind: UInt64 = 222

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
        retryTiming: SpotifyTransientRetry.Timing = .production,
    ) {
        credentials = SpotifyCredentials(
            accessToken: accessToken,
            clientToken: clientToken,
            invalidateAccessToken: invalidateAccessToken,
            invalidateClientToken: invalidateClientToken,
            transport: transport,
            retryTiming: retryTiming,
        )
    }

    /// Attributes for one batch of track uris, keyed by uri.
    ///
    /// This POST is a metadata read: the body names uris to look up and does not write
    /// library or playback state, so the shared replay-safe retry applies.
    ///
    /// Tracks Spotify answered for but has no attributes for are absent rather
    /// than mapped to empty values, so a caller cannot cache an absence that a
    /// later refresh might fill.
    func attributes(for uris: [String]) async throws -> [String: TrackAttributes] {
        guard !uris.isEmpty else { return [:] }

        let sent = try await credentials.retryingRefusedToken(replay: .safe) {
            try await send(uris)
        }

        guard sent.status == 200 else {
            throw TrackAttributesAPIError.requestFailed(sent.status)
        }

        return Self.decodeResponse(sent.body)
    }

    // MARK: - Transport

    private func send(_ uris: [String]) async throws -> SpotifyCredentials.Attempt {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.httpBody = Self.encodeRequest(uris)

        request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        try await credentials.sign(&request)

        debugLog("TrackAttributesAPI", "[POST] \(Self.endpoint.absoluteString) \(uris.count) tracks")

        let (data, response) = try await credentials.transport(request)

        guard let http = response as? HTTPURLResponse else {
            throw TrackAttributesAPIError.emptyResponse
        }

        return SpotifyCredentials.Attempt(body: data, http: http, request: request)
    }

    // MARK: - Request encoding

    /// Builds the `BatchedEntityRequest`: one `EntityRequest` per uri, each asking
    /// for both extensions.
    static func encodeRequest(_ uris: [String]) -> Data {
        var body = ProtobufWriter()
        for uri in uris where uri.hasPrefix("spotify:track:") {
            body.message(field: 2) { entityRequest in
                entityRequest.string(field: 1, uri)
                entityRequest.message(field: 2) { query in
                    query.varint(field: 1, trackKind)
                }
                entityRequest.message(field: 2) { query in
                    query.varint(field: 1, audioAttributesKind)
                }
            }
        }
        return body.data
    }

    // MARK: - Response decoding

    /// Walks the `BatchedExtensionResponse`:
    ///
    ///     repeated EntityExtensionDataArray extended_metadata = 2;
    ///     EntityExtensionDataArray { extension_kind = 2; repeated EntityExtensionData extension_data = 3; }
    ///     EntityExtensionData { entity_uri = 2; google.protobuf.Any extension_data = 3; }
    ///
    /// The Any's inner `value` bytes carry whichever payload the array's kind
    /// names. Malformed or unrecognized entries are skipped, never fatal.
    static func decodeResponse(_ data: Data) -> [String: TrackAttributes] {
        // The two extensions for one uri arrive as separate arrays, so entries are
        // assembled from parts and frozen once every array has been walked.
        var partials: [String: (popularity: Int?, bpm: Int?, key: String?)] = [:]

        for arrayField in ProtobufReader.fields(in: data) where arrayField.number == 2 {
            guard let arrayData = arrayField.bytesPayload else { continue }
            let kind = ProtobufReader.firstVarint(field: 2, in: arrayData)

            for entryField in ProtobufReader.fields(in: arrayData) where entryField.number == 3 {
                guard let entryData = entryField.bytesPayload,
                    let uri = ProtobufReader.firstString(field: 2, in: entryData),
                    let anyBytes = ProtobufReader.firstBytes(field: 3, in: entryData),
                    let payload = ProtobufReader.firstBytes(field: 2, in: anyBytes)
                else { continue }

                switch kind {
                case trackKind:
                    if let popularity = decodePopularity(payload) {
                        var partial = partials[uri] ?? (nil, nil, nil)
                        partial.popularity = popularity
                        partials[uri] = partial
                    }
                case audioAttributesKind:
                    let attributes = decodeAudioAttributes(payload)
                    if attributes.bpm != nil || attributes.key != nil {
                        var partial = partials[uri] ?? (nil, nil, nil)
                        partial.bpm = attributes.bpm
                        partial.key = attributes.key
                        partials[uri] = partial
                    }
                default:
                    continue
                }
            }
        }

        return partials.mapValues {
            TrackAttributes(popularity: $0.popularity, bpm: $0.bpm, key: $0.key)
        }
    }

    /// Track v4's `popularity` is a `sint32` — zigzag-encoded on the wire.
    static func decodePopularity(_ trackMessage: Data) -> Int? {
        guard let raw = ProtobufReader.firstVarint(field: 8, in: trackMessage) else {
            return nil
        }
        let magnitude = Int64(truncatingIfNeeded: raw >> 1)
        let value = raw & 1 == 1 ? ~magnitude : magnitude
        return Int(truncatingIfNeeded: value)
    }

    /// The private `playlistmixing.extensions.audio_attributes.v2.AudioAttributes`
    /// payload:
    ///
    ///     AudioAttributes { double bpm = 1; Key key = 2; }
    ///     Key             { string key = 1; int32 mode = 2; CamelotKey camelot_key = 3; }
    ///     CamelotKey      { string value = 1; string color = 2; }
    static func decodeAudioAttributes(_ payload: Data) -> (bpm: Int?, key: String?) {
        var bpm: Int?
        // Wire bytes are untrusted: NaN and infinities trap on Int conversion.
        if let rawBpm = ProtobufReader.firstDouble(field: 1, in: payload), rawBpm.isFinite {
            let rounded = Int(rawBpm.rounded())
            bpm = rounded > 0 ? rounded : nil
        }

        var key: String?
        if let keyMessage = ProtobufReader.firstBytes(field: 2, in: payload) {
            key = decodeAudioKey(keyMessage)
        }

        return (bpm, key)
    }

    private static func decodeAudioKey(_ keyMessage: Data) -> String? {
        if let camelotMessage = ProtobufReader.firstBytes(field: 3, in: keyMessage),
            let camelot = ProtobufReader.firstString(field: 1, in: camelotMessage),
            !camelot.isEmpty
        {
            return camelot
        }

        guard let name = ProtobufReader.firstString(field: 1, in: keyMessage), !name.isEmpty else {
            return nil
        }
        // The audio-analysis mode convention: 1 is major, everything else minor.
        let mode = ProtobufReader.firstVarint(field: 2, in: keyMessage) ?? 0
        return mode == 1 ? "\(name) Major" : "\(name) Minor"
    }
}

nonisolated enum TrackAttributesAPIError: Error, LocalizedError, Equatable {
    case emptyResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .emptyResponse:
            "Spotify returned no response"
        case let .requestFailed(status):
            "Spotify rejected the attribute request (HTTP \(status))"
        }
    }
}
