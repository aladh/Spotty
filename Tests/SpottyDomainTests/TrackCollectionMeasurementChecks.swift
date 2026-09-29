#if canImport(Darwin)
    import Darwin
    import Foundation
    import SpottyDomain
    import Testing

    /// Opt-in macOS CPU probes for pure collection policy, without desktop or engine dependencies.
    /// Compare repeated optimized runs; these have no machine-dependent pass/fail thresholds.
    struct TrackCollectionMeasurementTests {
        @Test(.enabled(if: ProcessInfo.processInfo.environment["SPOTTY_TRACK_ENRICHMENT_REPORT"] != nil))
        func measureTrackCollectionEnrichment() throws {
            let count = 10_000
            let iterations = 50
            let tracks = (0..<count).map { index in
                CatalogTrack(
                    id: "row-\(index)", uri: "spotify:track:synthetic-\(index)", title: "Track \(index)",
                    artist: "Artist", album: "Album", duration: 180, artworkURL: nil,
                    addedAt: nil, occurrenceUID: "server-\(index)")
            }
            let collection = CatalogTrackCollection(tracks: tracks)
            let original = tracks[count / 2]
            func metadata(_ track: CatalogTrack, changed: Bool) -> CatalogTrackMetadata {
                CatalogTrackMetadata(
                    track: CatalogTrack(
                        id: track.id, uri: track.uri, title: changed ? "Updated \(track.title)" : track.title,
                        artist: track.artist, album: track.album, duration: track.duration,
                        artworkURL: nil, addedAt: nil), requestedURI: track.uri)
            }
            let workloads: [(String, [String: CatalogTrackMetadata], Bool)] = [
                ("unrelated", ["spotify:track:unrelated": metadata(original, changed: true)], false),
                ("unchanged", [original.uri: metadata(original, changed: false)], false),
                ("one-change", [original.uri: metadata(original, changed: true)], true),
                (
                    "all-changed",
                    Dictionary(uniqueKeysWithValues: tracks.map { ($0.uri, metadata($0, changed: true)) }), true
                ),
            ]
            var reports: [[String: Any]] = []
            for (workload, entities, changes) in workloads {
                var result = collection.applyingMetadata(entities)
                let started = ContinuousClock.now
                let before = try cpuSeconds()
                for _ in 0..<iterations { result = collection.applyingMetadata(entities) }
                let cpu = try cpuSeconds() - before
                let elapsed = started.duration(to: .now).components
                #expect((result != nil) == changes)
                if let result {
                    #expect(result.tracks.map(\.id) == tracks.map(\.id))
                    #expect(result.tracks.map(\.occurrenceUID) == tracks.map(\.occurrenceUID))
                }
                reports.append([
                    "workload": workload, "cpuSeconds": cpu,
                    "wallSeconds": Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
                ])
            }
            let report = try JSONSerialization.data(
                withJSONObject: ["version": 1, "trackCount": count, "iterations": iterations, "measurements": reports],
                options: [.prettyPrinted, .sortedKeys])
            let path = try #require(ProcessInfo.processInfo.environment["SPOTTY_TRACK_ENRICHMENT_REPORT"])
            try report.write(to: URL(fileURLWithPath: path), options: .atomic)
        }

        @Test(.enabled(if: ProcessInfo.processInfo.environment["SPOTTY_TRACK_SORT_REPORT"] != nil))
        func measureTrackTableSorting() throws {
            let count = 10_000
            let iterations = 10
            let tracks = (0..<count).map { index in
                // A deterministic permutation avoids measuring already-sorted input. Repeated
                // values and missing dates exercise source-order ties and nil-last date ordering.
                let value = (index * 7_919) % count
                return CatalogTrack(
                    id: "row-\(index)", uri: "spotify:track:synthetic-\(index)", title: "Track \(value)",
                    artist: "Artist \(value % 100)", album: "Album \(value % 500)",
                    duration: Double(value % 600), artworkURL: nil,
                    addedAt: index.isMultiple(of: 7) ? nil : Date(timeIntervalSince1970: Double(value % 1_000)))
            }
            let collection = CatalogTrackCollection(tracks: tracks)
            let workloads: [(String, [KeyPathComparator<TrackTableRow>])] = [
                ("date", [KeyPathComparator(\TrackTableRow.dateAddedSortValue, order: .reverse)]),
                ("duration", [KeyPathComparator(\TrackTableRow.duration)]),
                ("title", [KeyPathComparator(\TrackTableRow.title)]),
                ("artist-title", [KeyPathComparator(\TrackTableRow.artist), KeyPathComparator(\TrackTableRow.title)]),
            ]
            var reports: [[String: Any]] = []
            for (workload, comparators) in workloads {
                var cache = TrackTableDisplayCache(collection, sortOrder: comparators)
                let expected = cache.rows.map(\.id)
                let started = ContinuousClock.now
                let before = try cpuSeconds()
                for _ in 0..<iterations {
                    cache = TrackTableDisplayCache(collection, sortOrder: comparators)
                }
                let cpu = try cpuSeconds() - before
                let elapsed = started.duration(to: .now).components
                #expect(cache.rows.map(\.id) == expected)
                reports.append([
                    "workload": workload, "cpuSeconds": cpu,
                    "wallSeconds": Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
                ])
            }
            let report = try JSONSerialization.data(
                withJSONObject: ["version": 1, "trackCount": count, "iterations": iterations, "measurements": reports],
                options: [.prettyPrinted, .sortedKeys])
            let path = try #require(ProcessInfo.processInfo.environment["SPOTTY_TRACK_SORT_REPORT"])
            try report.write(to: URL(fileURLWithPath: path), options: .atomic)
        }

        @Test(.enabled(if: ProcessInfo.processInfo.environment["SPOTTY_TRACK_NORMALIZATION_REPORT"] != nil))
        func measureTrackOccurrenceNormalization() throws {
            let iterations = 30
            var reports: [[String: Any]] = []
            for count in [500, 10_000, 20_000] {
                for workload in ["unique", "server-occurrences", "sparse-duplicates", "ambiguous"] {
                    let tracks = (0..<count).map { index in
                        let identity: Int
                        switch workload {
                        case "ambiguous": identity = index % 100
                        case "sparse-duplicates": identity = index.isMultiple(of: 100) ? 0 : index
                        default: identity = index
                        }
                        return CatalogTrack(
                            id: "row-\(identity)", uri: "spotify:track:synthetic-\(identity)", title: "Track \(index)",
                            artist: "Artist", album: "Album", duration: 180, artworkURL: nil, addedAt: nil,
                            occurrenceUID: workload == "unique" ? nil : "server-\(identity)")
                    }
                    var result = CatalogTrackCollection(tracks: tracks)
                    let started = ContinuousClock.now
                    let before = try cpuSeconds()
                    for _ in 0..<iterations { result = CatalogTrackCollection(tracks: tracks) }
                    let cpu = try cpuSeconds() - before
                    let elapsed = started.duration(to: .now).components
                    let resultCount = result.tracks.count
                    let distinctIDCount = Set(result.tracks.map(\.id)).count
                    let titlesMatch = zip(result.tracks, tracks).allSatisfy { $0.title == $1.title }
                    #expect(resultCount == count)
                    #expect(distinctIDCount == count)
                    #expect(titlesMatch)
                    reports.append([
                        "trackCount": count, "workload": workload, "cpuSeconds": cpu,
                        "wallSeconds": Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
                    ])
                }
            }
            let report = try JSONSerialization.data(
                withJSONObject: ["version": 1, "iterations": iterations, "measurements": reports],
                options: [.prettyPrinted, .sortedKeys])
            let path = try #require(ProcessInfo.processInfo.environment["SPOTTY_TRACK_NORMALIZATION_REPORT"])
            try report.write(to: URL(fileURLWithPath: path), options: .atomic)
        }

        private func cpuSeconds() throws -> Double {
            var usage = rusage()
            try #require(getrusage(RUSAGE_SELF, &usage) == 0)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        }
    }
#endif
