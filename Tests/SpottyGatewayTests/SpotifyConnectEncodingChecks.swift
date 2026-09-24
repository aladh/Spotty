import Foundation
import SpottyDomain
import SpottyRuntimeContracts
import Testing
@testable import SpottyGateway

@Suite("Spotify Connect command encoding")
struct SpotifyConnectEncodingTests {
    @Test(arguments: [
        (SpotifyConnectCommand.pause, #"{"endpoint":"pause"}"#),
        (.resume, #"{"endpoint":"resume"}"#),
        (.next, #"{"endpoint":"skip_next"}"#),
        (.previous, #"{"endpoint":"skip_prev"}"#),
        (.seek(to: 12_345), #"{"endpoint":"seek_to","value":12345}"#),
        (.seek(to: -1), #"{"endpoint":"seek_to","value":0}"#),
        (.shuffle(true), #"{"endpoint":"set_shuffling_context","value":true}"#),
        (.shuffle(false), #"{"endpoint":"set_shuffling_context","value":false}"#),
        (.repeatContext(true), #"{"endpoint":"set_repeating_context","value":true}"#),
        (.repeatContext(false), #"{"endpoint":"set_repeating_context","value":false}"#),
        (.repeatTrack(true), #"{"endpoint":"set_repeating_track","value":true}"#),
        (.repeatTrack(false), #"{"endpoint":"set_repeating_track","value":false}"#),
        (
            .addToQueue("spotify:track:queued"),
            #"{"endpoint":"add_to_queue","track":{"uri":"spotify:track:queued","uid":"","metadata":{}}}"#
        ),
        (
            .setQueue(next: [], prev: [], queueRevision: "empty"),
            #"{"endpoint":"set_queue","next_tracks":[],"prev_tracks":[],"queue_revision":"empty"}"#
        ),
    ])
    func transportCommandsEncodeOnlyTheirRequiredFields(
        command: SpotifyConnectCommand, expectedJSON: String
    ) throws {
        try expectPayload(command, matches: expectedJSON)
    }

    @Test(arguments: [nil, -1, 0, 7] as [Int?])
    func trackSelectionAlwaysTargetsTheTrackURI(index: Int?) throws {
        try expectPayload(
            .play(uri: "spotify:track:selected", trackIndex: index),
            matches: #"""
                {"endpoint":"play",
                 "context":{"uri":"spotify:track:selected","url":"context://spotify:track:selected",
                            "options":{"skip_to":{"track_uri":"spotify:track:selected"}}},
                 "options":{"skip_to":{"track_uri":"spotify:track:selected"}}}
                """#)
    }

    @Test(arguments: [nil, -1] as [Int?])
    func collectionSelectionOmitsMissingOrInvalidIndex(index: Int?) throws {
        try expectPayload(
            .play(uri: "spotify:playlist:selected", trackIndex: index),
            matches: #"""
                {"endpoint":"play",
                 "context":{"uri":"spotify:playlist:selected","url":"context://spotify:playlist:selected"}}
                """#)
    }

    @Test(arguments: [0, 7])
    func collectionSelectionPreservesTheOccurrenceIndex(index: Int) throws {
        try expectPayload(
            .play(uri: "spotify:album:selected", trackIndex: index),
            matches: """
                {"endpoint":"play",
                 "context":{"uri":"spotify:album:selected","url":"context://spotify:album:selected",
                            "options":{"skip_to":{"track_index":\(index)}}},
                 "options":{"skip_to":{"track_index":\(index)}}}
                """)
    }

    @Test
    func orderedSelectionPreservesDuplicatesWithoutInventingAContext() throws {
        try expectPayload(
            .play(trackURIs: ["spotify:track:first", "spotify:track:second", "spotify:track:first"]),
            matches: #"""
                {"endpoint":"play","context":{"uri":"","url":"","pages":[{"tracks":[
                    {"uri":"spotify:track:first"},{"uri":"spotify:track:second"},{"uri":"spotify:track:first"}
                ]}]}}
                """#)
    }

    @Test
    func queueReplacementPreservesProtocolRowsAndAllProvenance() throws {
        try expectPayload(
            .setQueue(
                next: [
                    QueueProtocolTrack(
                        uri: "spotify:track:keep", uid: "q0", provider: "queue",
                        metadata: ["sentinel": "keep", "is_queued": "true"],
                        albumURI: "spotify:album:fixture", artistURI: "spotify:artist:fixture"),
                    QueueProtocolTrack(
                        uri: "spotify:delimiter", provider: "delimiter", metadata: ["sentinel": "delimiter"]),
                    QueueProtocolTrack(
                        uri: "spotify:track:keep", uid: "a0", provider: "autoplay", metadata: ["sentinel": "autoplay"]),
                ],
                prev: [
                    QueueProtocolTrack(
                        uri: "spotify:track:prev", uid: "p0", provider: "context", metadata: ["sentinel": "prev"],
                        removed: ["removed-reason"], blocked: ["blocked-reason"],
                        restrictions: ["disallow_skipping_next_reasons": ["restriction-reason"]],
                        disallowReasons: ["disallow-reason"])
                ],
                queueRevision: "rev-9"),
            matches: #"""
                {"endpoint":"set_queue","queue_revision":"rev-9","next_tracks":[
                    {"uri":"spotify:track:keep","uid":"q0","provider":"queue",
                     "metadata":{"sentinel":"keep","is_queued":"true"},
                     "album_uri":"spotify:album:fixture","artist_uri":"spotify:artist:fixture"},
                    {"uri":"spotify:delimiter","uid":"","provider":"delimiter","metadata":{"sentinel":"delimiter"}},
                    {"uri":"spotify:track:keep","uid":"a0","provider":"autoplay","metadata":{"sentinel":"autoplay"}}
                ],"prev_tracks":[
                    {"uri":"spotify:track:prev","uid":"p0","provider":"context","metadata":{"sentinel":"prev"},
                     "removed":["removed-reason"],"blocked":["blocked-reason"],
                     "restrictions":{"disallow_skipping_next_reasons":["restriction-reason"]},
                     "disallow_reasons":["disallow-reason"]}
                ]}
                """#)
    }

    @Test
    func commandIdentityIsStableForOneEncodingAndUniqueForTheNext() throws {
        let command = SpotifyConnectWireCommand(.pause)
        let first = try object(JSONEncoder().encode(command))
        let repeated = try object(JSONEncoder().encode(command))
        let next = try object(JSONEncoder().encode(SpotifyConnectWireCommand(.pause)))
        let firstID = try commandID(first)
        #expect(try firstID == commandID(repeated))
        #expect(try firstID != commandID(next))
    }

    @Test
    func transportWrapsAndSignsTheSemanticCommand() async throws {
        let api = SpotifyConnectAPI(
            accessToken: { "test-access" }, clientToken: { "test-client" },
            transport: { request in
                #expect(request.url?.path == "/connect-state/v1/player/command/from/source/to/target")
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-access")
                #expect(request.value(forHTTPHeaderField: "Client-Token") == "test-client")
                let envelope = try object(#require(request.httpBody))
                #expect(envelope["connection_type"] as? String == "wlan")
                try expectIdentifier(envelope["intent_id"])
                let command = try #require(envelope["command"] as? [String: Any])
                #expect(command["endpoint"] as? String == "pause")
                _ = try commandID(command)
                let url = try #require(request.url)
                let response = try #require(
                    HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil))
                return (Data(), response)
            })
        try await api.send(.pause, from: "source", to: "target")
    }

    private func expectPayload(_ command: SpotifyConnectCommand, matches expectedJSON: String) throws {
        var payload = try object(JSONEncoder().encode(SpotifyConnectWireCommand(command)))
        _ = try commandID(payload)
        payload.removeValue(forKey: "logging_params")
        let expected = try object(Data(expectedJSON.utf8))
        let actualJSON = try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)
        let expectedJSON = try JSONSerialization.data(withJSONObject: expected, options: .sortedKeys)
        #expect(String(decoding: actualJSON, as: UTF8.self) == String(decoding: expectedJSON, as: UTF8.self))
    }
}

private func object(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func commandID(_ command: [String: Any]) throws -> String {
    let parameters = try #require(command["logging_params"] as? [String: Any])
    return try expectIdentifier(parameters["command_id"])
}

@discardableResult
private func expectIdentifier(_ value: Any?) throws -> String {
    let identifier = try #require(value as? String)
    #expect(identifier.count == 32)
    #expect(identifier.allSatisfy { "0123456789abcdef".contains($0) })
    return identifier
}
