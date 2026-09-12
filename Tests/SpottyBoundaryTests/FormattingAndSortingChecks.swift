import Testing
//
//  FormattingAndSortingChecks.swift
//  Spotty
//

import SpottyDomain
import Foundation
@testable import SpottyCore
@testable import SpottyGateway
import SpottyRuntimeContracts

@Suite("Formatting")
struct FormattingTests {
    @Test
    @MainActor
    func testFormatting() {
        do {
            #expect((formatDuration(0)) == ("0:00"), "zero duration")
            #expect((formatDuration(59)) == ("0:59"), "sub-minute duration")
            #expect((formatDuration(61)) == ("1:01"), "crossing the minute")
            // Long tracks are not wrapped into hours.
            #expect((formatDuration(3_661)) == ("61:01"), "hour-plus duration")
            #expect((formatCatalogDuration(3.5)) == ("0:04"), "catalog durations round to nearest second")
            #expect((formatCatalogDuration(-0.5)) == ("0:00"), "catalog durations clamp invalid values")
            #expect(
                (formatCatalogDuration(.greatestFiniteMagnitude)) == ("0:00"),
                "catalog durations reject finite values outside Int range")
            #expect(
                (roundedCatalogDurationSeconds(61.6)) == (62), "catalog duration seconds use the same rounded value")
            #expect(
                (formatDuration(.greatestFiniteMagnitude)) == ("0:00"),
                "player durations reject finite values outside Int range")
            #expect((formatPlaylistDuration(2_564)) == ("42 min 44 sec"), "playlist duration uses Spotify-style units")
            #expect((formatPlaylistDuration(60)) == ("1 min"), "playlist duration omits a zero seconds component")
            #expect((formatPlaylistDuration(-5)) == ("0 sec"), "playlist duration clamps invalid values")
            #expect(
                (formatPlaylistDuration(3_600)) == ("1 hr"), "playlist duration uses hours without trailing minutes")
            #expect((formatPlaylistDuration(3_661)) == ("1 hr 1 min"), "playlist duration uses hours and minutes")
            #expect(
                (formatPlaylistDuration(.greatestFiniteMagnitude)) == ("0 sec"),
                "playlist durations reject finite values outside Int range")
            #expect((formatDateAdded(nil)) == ("—"), "missing date renders an em dash")
            #expect(
                (PlaylistDescription.plainText(
                    from:
                        #"A collection by <a href="https://open.spotify.com/artist/1">Bonobo</a> &amp; friends.<br>New music."#
                )) == ("A collection by Bonobo & friends.\nNew music."), "playlist descriptions discard Spotify markup")
            #expect(
                (CatalogMapping.spotifyDate(from: "1970-01-01T00:00:00Z")) == nil,
                "Spotify's epoch sentinel maps to a missing date")
            #expect(
                (CatalogMapping.spotifyDate(from: "2026-08-20T12:34:56Z") != nil) == true,
                "a real Spotify timestamp still parses")

            // Clock skew must not render negative durations.
            #expect((formatDuration(-5)) == ("0:00"), "negative duration clamps to zero")
        }

        func track(uri: String, duration: TimeInterval = 1) -> CatalogTrack {
            CatalogTrack(
                id: uri,
                uri: uri,
                title: uri,
                artist: "",
                album: "",
                duration: duration,
                artworkURL: nil,
                addedAt: nil
            )
        }

        func sortValues(
            popularity: Int? = nil,
            bpm: Int? = nil,
            key: String? = nil
        ) -> TrackTableSortValues {
            TrackTableSortValues(popularity: popularity, bpm: bpm, key: key)
        }

        func sortedURIs(
            _ tracks: [CatalogTrack],
            using comparator: KeyPathComparator<TrackTableRow>,
            sortValues: [String: TrackTableSortValues] = [:],
        ) -> [String] {
            let collection = CatalogTrackCollection(tracks: tracks)
            var cache = TrackTableDisplayCache(collection)
            _ = cache.update(
                collection,
                sortValues: sortValues,
                sortValuesRevision: 1,
                sortOrder: [comparator]
            )
            return cache.rows.map(\.track.uri)
        }

        do {
            let short = track(uri: "short")
            let long = track(uri: "long", duration: 240)
            let missing = track(uri: "missing")
            let values = [
                "short": sortValues(popularity: 10, bpm: 90, key: "2A"),
                "long": sortValues(popularity: 80, bpm: 130, key: "10A"),
            ]

            #expect(
                (sortedURIs(
                    [long, short],
                    using: KeyPathComparator(\TrackTableRow.popularitySortValue),
                    sortValues: values
                )) == (["short", "long"]), "popularity sorts ascending from displayed enrichment")
            #expect(
                (sortedURIs(
                    [missing, short, long],
                    using: KeyPathComparator(\TrackTableRow.bpmSortValue, order: .reverse),
                    sortValues: values
                )) == (["long", "short", "missing"]), "BPM reverses while missing enrichment stays last")
            #expect(
                (sortedURIs(
                    [long, short],
                    using: KeyPathComparator(\TrackTableRow.keySortValue),
                    sortValues: values
                )) == (["short", "long"]), "Camelot keys use numeric ordering")
            #expect(
                (sortedURIs([long, short], using: KeyPathComparator(\TrackTableRow.duration))) == (["short", "long"]),
                "time sorts by numeric duration")

            let equalAttributes = [
                "short": sortValues(popularity: 50),
                "long": sortValues(popularity: 50),
            ]
            #expect(
                (sortedURIs(
                    [missing, long, short],
                    using: KeyPathComparator(\TrackTableRow.popularitySortValue),
                    sortValues: equalAttributes
                )) == (["long", "short", "missing"]),
                "missing values sort deterministically and equal values keep source order")
        }
    }
}
