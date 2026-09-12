import Testing
//
//  TrackAttributeChecks.swift
//  Spotty
//

import Foundation
@testable import SpottyCore
@testable import SpottyGateway
import SpottyRuntimeContracts

@Suite("Track Attribute")
struct TrackAttributeTests {
    @Test
    @MainActor
    func testTrackAttribute() {
        // Payload builders mirroring the wire shapes Spotify answers with.

        func array(kind: UInt64, uri: String, payload: Data) -> Data {
            var writer = ProtobufWriter()
            writer.varint(field: 2, kind)
            writer.message(field: 3) { entry in
                // google.protobuf.Any: type_url = 1, value = 2.
                entry.message(field: 3) { any in
                    any.string(field: 1, "type.googleapis.com/spotify.extendedmetadata.Test")
                    any.bytes(field: 2, payload)
                }
                entry.string(field: 2, uri)
            }
            return writer.data
        }

        func response(_ arrays: [Data]) -> Data {
            var writer = ProtobufWriter()
            for array in arrays {
                writer.bytes(field: 2, array)
            }
            return writer.data
        }

        func trackPayload(popularity: Int64?) -> Data {
            var writer = ProtobufWriter()
            if let popularity {
                let zigzag = UInt64(bitPattern: Int64((popularity << 1) ^ (popularity >> 63)))
                writer.varint(field: 8, zigzag)
            }
            return writer.data
        }

        func audioPayload(bpm: Double? = nil, keyName: String? = nil, mode: UInt64 = 0, camelot: String? = nil) -> Data
        {
            var writer = ProtobufWriter()
            if let bpm {
                writer.double(field: 1, bpm)
            }
            if keyName != nil || camelot != nil {
                writer.message(field: 2) { key in
                    if let keyName {
                        key.string(field: 1, keyName)
                        key.varint(field: 2, mode)
                    }
                    if let camelot {
                        key.message(field: 3) { camelotKey in
                            camelotKey.string(field: 1, camelot)
                        }
                    }
                }
            }
            return writer.data
        }

        do {
            let uri = "spotify:track:6rqhFgbbKwnb9MLmUQDhG6"
            let combined = TrackAttributesAPI.decodeResponse(
                response([
                    array(kind: TrackAttributesAPI.trackKind, uri: uri, payload: trackPayload(popularity: 87)),
                    array(
                        kind: TrackAttributesAPI.audioAttributesKind,
                        uri: uri,
                        payload: audioPayload(bpm: 123.456, keyName: "C#", mode: 0, camelot: "8B")
                    ),
                ]))[uri]

            #expect((combined) != nil, "combined attributes decoded")
            if let attributes = combined {
                #expect((attributes.popularity ?? -1) == (87), "popularity")
                #expect((attributes.bpm ?? -1) == (123), "bpm rounds")
                #expect((attributes.key ?? "") == ("8B"), "camelot label preferred (what the desktop client shows)")
            }

            let major = TrackAttributesAPI.decodeResponse(
                response([
                    array(
                        kind: TrackAttributesAPI.audioAttributesKind,
                        uri: "spotify:track:fallback",
                        payload: audioPayload(keyName: "F#", mode: 1)
                    )
                ]))["spotify:track:fallback"]
            #expect((major?.key) == ("F# Major"), "key falls back to name + major mode")

            let minor = TrackAttributesAPI.decodeResponse(
                response([
                    array(
                        kind: TrackAttributesAPI.audioAttributesKind,
                        uri: "spotify:track:fallback",
                        payload: audioPayload(keyName: "A", mode: 0)
                    )
                ]))["spotify:track:fallback"]
            #expect((minor?.key) == ("A Minor"), "key falls back to name + minor mode")

            let negative = TrackAttributesAPI.decodeResponse(
                response([
                    array(
                        kind: TrackAttributesAPI.trackKind, uri: "spotify:track:neg",
                        payload: trackPayload(popularity: -7))
                ]))["spotify:track:neg"]
            #expect((negative?.popularity) == (-7), "zigzag decodes negative popularity")

            let partial = TrackAttributesAPI.decodeResponse(
                response([
                    array(
                        kind: TrackAttributesAPI.trackKind, uri: "spotify:track:p",
                        payload: trackPayload(popularity: 42)),
                    // An unrecognized kind contributes nothing; the entry keeps its popularity.
                    array(kind: 999, uri: "spotify:track:p", payload: Data([0x01])),
                ]))["spotify:track:p"]
            #expect((partial?.popularity) == (42), "partial entries keep what arrived")
            #expect((partial?.bpm) == nil, "missing bpm stays absent")

            #expect((TrackAttributesAPI.decodeResponse(Data()).isEmpty) == true, "empty response yields nothing")
            #expect(
                (TrackAttributesAPI.decodeResponse(Data([0x12, 0x05])).isEmpty) == true,
                "truncated response yields nothing"
            )
            let truncated = response([
                array(kind: TrackAttributesAPI.audioAttributesKind, uri: "spotify:track:x", payload: Data([0x11]))
            ])
            #expect(
                (TrackAttributesAPI.decodeResponse(truncated).isEmpty) == true, "truncated attribute payload tolerated")

            // A zero tempo is no tempo: the columns stay blank rather than reading 0 BPM.
            let zeroBPM = TrackAttributesAPI.decodeResponse(
                response([
                    array(
                        kind: TrackAttributesAPI.audioAttributesKind, uri: "spotify:track:zb",
                        payload: audioPayload(bpm: 0)
                    )
                ]))
            #expect((zeroBPM["spotify:track:zb"]) == nil, "zero bpm contributes no attributes")

            // An entry without its uri cannot be attributed to anything.
            var anonymous = ProtobufWriter()
            anonymous.message(field: 3) { any in
                any.bytes(field: 2, trackPayload(popularity: 50))
            }
            #expect(
                (TrackAttributesAPI.decodeResponse(response([anonymous.data])).isEmpty) == true,
                "entries without uris are skipped")

            // Zero is a real popularity and sits exactly on the zigzag sign boundary.
            let zero = TrackAttributesAPI.decodeResponse(
                response([
                    array(
                        kind: TrackAttributesAPI.trackKind, uri: "spotify:track:z", payload: trackPayload(popularity: 0)
                    )
                ]))
            #expect((zero["spotify:track:z"]?.popularity ?? -1) == (0), "zigzag keeps a zero popularity")
        }

        do {
            let data = TrackAttributesAPI.encodeRequest([
                "spotify:track:a",
                "spotify:local:not-a-real-track",
                "spotify:episode:no",
                "spotify:track:b",
            ])

            var entityURIs: [String] = []
            var kindsPerEntity: [[UInt64]] = []
            for entityField in ProtobufReader.fields(in: data) where entityField.number == 2 {
                guard let entity = entityField.bytesPayload else { continue }
                if let uri = ProtobufReader.firstString(field: 1, in: entity) {
                    entityURIs.append(uri)
                }
                let kinds = ProtobufReader.fields(in: entity)
                    .filter { $0.number == 2 }
                    .compactMap(\.bytesPayload)
                    .compactMap { ProtobufReader.firstVarint(field: 1, in: $0) }
                kindsPerEntity.append(kinds)
            }

            #expect((entityURIs) == (["spotify:track:a", "spotify:track:b"]), "non-track uris are skipped")
            #expect(
                (kindsPerEntity)
                    == ([
                        [TrackAttributesAPI.trackKind, TrackAttributesAPI.audioAttributesKind],
                        [TrackAttributesAPI.trackKind, TrackAttributesAPI.audioAttributesKind],
                    ]), "each track asks for both extensions")
        }

        do {
            func track(_ uri: String) -> CatalogTrack {
                CatalogTrack(
                    id: uri, uri: uri, title: uri, artist: "", album: "",
                    duration: 0, artworkURL: nil, addedAt: nil
                )
            }

            let tracks =
                (0..<1_100).map { track("spotify:track:\($0)") }
                + [track("spotify:track:4"), track("spotify:episode:not-a-track")]
            let capped = CatalogMetadataRepository.attributeURIsToRequest(
                from: tracks,
                excluding: [],
                limit: 1_000
            )
            #expect((capped.count) == (1_000), "metadata scheduling respects its exact cap")
            #expect((capped.first) == ("spotify:track:0"), "metadata scheduling keeps source order")
            #expect((capped.last) == ("spotify:track:999"), "metadata scheduling ends at the cap")

            let excluded = CatalogMetadataRepository.attributeURIsToRequest(
                from: [track("spotify:track:cached"), track("spotify:track:in-flight"), track("spotify:track:new")],
                excluding: ["spotify:track:cached", "spotify:track:in-flight"],
                limit: 10
            )
            #expect((excluded) == (["spotify:track:new"]), "cached and in-flight metadata is not rescheduled")
            #expect(
                (CatalogMetadataRepository.attributeURIsToRequest(from: tracks, excluding: [], limit: 0).isEmpty)
                    == true,
                "a zero request limit schedules nothing")
        }
    }
}
