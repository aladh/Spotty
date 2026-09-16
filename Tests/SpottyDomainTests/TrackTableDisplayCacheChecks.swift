import Testing
import SpottyDomain
import Foundation

@Suite("Track Table Display Cache")
struct TrackTableDisplayCacheTests {
    @Test
    func testTrackTableDisplayCache() {
        func track(
            id: String,
            title: String,
            artist: String = "Artist",
            album: String = "Album",
            addedAt: Date? = nil
        ) -> CatalogTrack {
            CatalogTrack(
                id: id,
                uri: "spotify:track:\(id)",
                title: title,
                artist: artist,
                album: album,
                duration: 1,
                artworkURL: nil,
                addedAt: addedAt
            )
        }

        do {
            var collection = CatalogTrackCollection()
            let initialVersion = collection.version

            collection.replace([track(id: "a", title: "A"), track(id: "b", title: "B")])
            #expect((collection.version != initialVersion) == true, "first replace mints a new version")
            #expect((collection.tracks.map(\.id)) == (["a", "b"]), "replace publishes the new rows")

            let afterFirstReplace = collection.version
            collection.replace(collection.tracks)
            #expect((collection.version != afterFirstReplace) == true, "equal content still mints a new version")

            var copy = collection
            #expect((copy.version) == (collection.version), "a copy keeps the current version until it replaces")
            copy.replace([track(id: "c", title: "C")])
            #expect(
                (copy.version != collection.version) == true,
                "copy-and-replace mints a version the original does not share"
            )
            #expect((collection.tracks.map(\.id)) == (["a", "b"]), "the original rows stay on the unreplaced copy")

            let seeded = CatalogTrackCollection(tracks: [track(id: "seed", title: "Seed")])
            #expect((seeded.version != collection.version) == true, "seeded construction mints its own version")
            #expect(
                (CatalogTrackCollection().version != CatalogTrackCollection().version) == true,
                "two fresh owners mint distinct versions")
        }

        do {
            let alpha = track(id: "alpha", title: "Alpha", artist: "B", album: "Z")
            let beta = track(id: "beta", title: "Beta", artist: "A", album: "Y")
            let gamma = track(id: "gamma", title: "Gamma", artist: "A", album: "X")
            let source = [gamma, alpha, beta]

            var collection = CatalogTrackCollection()
            collection.replace(source)
            var cache = TrackTableDisplayCache(collection)
            #expect((cache.rows.map(\.id)) == (["gamma", "alpha", "beta"]), "empty sort keeps source order")

            let snapshot = collection
            collection.replace([gamma, track(id: "middle", title: "Replaced"), beta])
            #expect((!cache.update(snapshot, sortOrder: [])) == true, "the unreplaced copy is a cache hit")
            #expect((cache.rows.map(\.id)) == (["gamma", "alpha", "beta"]), "a cache hit keeps the previous rows")
            #expect((cache.update(collection, sortOrder: [])) == true, "replace of the live collection recomputes")
            #expect((cache.rows.map(\.id)) == (["gamma", "middle", "beta"]), "rows follow the replaced generation")

            collection.replace(source)
            _ = cache.update(collection, sortOrder: [])
            let titleAscending = [KeyPathComparator(\TrackTableRow.title)]
            #expect((cache.update(collection, sortOrder: titleAscending)) == true, "sort-field change recomputes")
            #expect(
                (cache.rows.map(\.id)) == (["alpha", "beta", "gamma"]), "title ascending uses the native comparator")

            let titleDescending = [
                KeyPathComparator(\TrackTableRow.title, order: .reverse)
            ]
            #expect((cache.update(collection, sortOrder: titleDescending)) == true, "descending recomputes")
            #expect((cache.rows.map(\.id)) == (["gamma", "beta", "alpha"]), "title descending reverses the column")

            let artistThenReverseTitle = [
                KeyPathComparator(\TrackTableRow.artist),
                KeyPathComparator(\TrackTableRow.title, order: .reverse),
            ]
            #expect(
                (cache.update(collection, sortOrder: artistThenReverseTitle)) == true, "multi-comparator recomputes")
            #expect(
                (cache.rows.map(\.id)) == (["gamma", "beta", "alpha"]),
                "artist then reverse title keeps comparator order")

            #expect(
                (!cache.update(collection, sortOrder: artistThenReverseTitle)) == true,
                "an unchanged collection and sort order is a cache hit")

            var other = CatalogTrackCollection()
            other.replace([beta])
            #expect((cache.update(other, sortOrder: [])) == true, "a different collection recomputes")
            #expect((cache.rows.map(\.id)) == (["beta"]), "rows follow the new collection")

            let older = Date(timeIntervalSince1970: 1_000)
            let newer = Date(timeIntervalSince1970: 2_000)
            var dated = CatalogTrackCollection()
            dated.replace([
                track(id: "undated", title: "Undated", addedAt: nil),
                track(id: "old", title: "Old", addedAt: older),
                track(id: "new", title: "New", addedAt: newer),
            ])
            var dateCache = TrackTableDisplayCache(dated)
            #expect(
                (dateCache.update(dated, sortOrder: [KeyPathComparator(\TrackTableRow.dateAddedSortValue)])) == true,
                "date-added sort recomputes")
            #expect(
                (dateCache.rows.map(\.id)) == (["old", "new", "undated"]),
                "nil dates sink below present dates for the table column")
            #expect(
                (dateCache.update(
                    dated,
                    sortOrder: [KeyPathComparator(\TrackTableRow.dateAddedSortValue, order: .reverse)]
                )) == true, "the playlist's recently-added projection is newest first")
            #expect(
                (dateCache.rows.map(\.id)) == (["new", "old", "undated"]), "newest date-added rows precede older rows")
            #expect(
                (dateCache.rows.map(\.sourceIndex)) == ([2, 1, 0]),
                "playlist source positions stay attached after sorting")
            #expect((dateCache.update(dated, sortOrder: [])) == true, "clearing the projection restores source order")
            #expect(
                (dated.tracks.map(\.id)) == (["undated", "old", "new"]),
                "the source collection remains oldest-to-newest")
            #expect(
                (dateCache.rows.map(\.id)) == (["undated", "old", "new"]), "clearing sorting restores the source order")
            #expect(
                (dateCache.rows.map(\.sourceIndex)) == ([0, 1, 2]),
                "clearing sorting restores playlist source positions")

            let first = track(id: "uid-a", title: "Zebra")
            let second = CatalogTrack(
                id: "uid-b",
                uri: first.uri,
                title: "Alpha",
                artist: first.artist,
                album: first.album,
                duration: first.duration,
                artworkURL: nil,
                addedAt: nil
            )
            var duplicates = CatalogTrackCollection()
            duplicates.replace([first, second])
            var duplicateCache = TrackTableDisplayCache(duplicates)
            _ = duplicateCache.update(duplicates, sortOrder: titleAscending)
            #expect(
                (duplicateCache.rows.map(\.id)) == (["uid-b", "uid-a"]),
                "duplicate occurrences keep distinct identities after sort")

            let tiedSecond = CatalogTrack(
                id: "uid-c",
                uri: first.uri,
                title: first.title,
                artist: first.artist,
                album: first.album,
                duration: first.duration,
                artworkURL: nil,
                addedAt: nil
            )
            duplicates.replace([first, tiedSecond])
            _ = duplicateCache.update(duplicates, sortOrder: titleAscending)
            #expect(
                (duplicateCache.rows.map(\.id)) == (["uid-a", "uid-c"]), "equal duplicate occurrences keep source order"
            )

            var replacement = CatalogTrackCollection()
            replacement.replace([alpha, beta, gamma])
            var replacementCache = TrackTableDisplayCache(replacement)
            var forked = replacement
            forked.replace([alpha, track(id: "beta-2", title: "Omega"), gamma])
            #expect(
                (replacementCache.update(forked, sortOrder: titleAscending)) == true,
                "copy-and-replace of a same-count middle row recomputes")
            #expect(
                (replacementCache.rows.map(\.id)) == (["alpha", "gamma", "beta-2"]),
                "middle replacement participates in the new sort")
            #expect(
                (forked.version != replacement.version) == true, "the unreplaced original is still a distinct version")

            let selection: Set<String> = ["alpha", "gone", "gamma"]
            #expect(
                (TrackTableDisplayCache.prunedSelection(selection, from: forked.tracks)) == (["alpha", "gamma"]),
                "selection pruning drops identities that left the authoritative collection")
            #expect(
                (TrackTableDisplayCache.prunedSelection([], from: forked.tracks)) == ([]), "empty selection stays empty"
            )
        }
    }
}
