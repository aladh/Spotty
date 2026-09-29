import Foundation
import SpottyDomain
import Testing

struct CatalogTrackContributionsTests {
    private let uri = "spotify:track:shared"

    @Test(arguments: [false, true])
    func precedenceIsIndependentOfArrivalAndRemovalRevealsEverySource(reverse: Bool) {
        let sources: [CatalogTrackContributions.Source] = [
            .playback, .search, .playlist, .discography, .album, .library,
        ]
        var contributions = CatalogTrackContributions()
        for (index, source) in (reverse ? Array(sources.enumerated().reversed()) : Array(sources.enumerated())) {
            contributions = contributions.replacing([track(title: String(index))], from: source).next
        }
        for index in sources.indices.reversed() {
            #expect(contributions.displayTrack(for: uri)?.title == String(index))
            #expect(contributions.browsingTrack(for: uri)?.title == (index == 0 ? nil : String(index)))
            contributions = contributions.replacing([], from: sources[index]).next
        }
        #expect(contributions.displayTrack(for: uri) == nil)
        #expect(contributions.browsingTrack(for: uri) == nil)
    }

    @Test func hiddenWritesCommitWithoutInvalidatingEffectiveValues() {
        var contributions = CatalogTrackContributions().replacing([track(title: "Preferred")], from: .library).next
        let hidden = contributions.replacing([track(title: "New fallback")], from: .search)
        #expect(hidden.displayChangedURIs.isEmpty && hidden.browsingInvalidatedURIs.isEmpty)
        #expect(hidden.next.displayTrack(for: uri)?.title == "Preferred")
        contributions = hidden.next.replacing([], from: .library).next
        #expect(contributions.displayTrack(for: uri)?.title == "New fallback")
        #expect(contributions.browsingTrack(for: uri)?.title == "New fallback")
    }

    @Test func browsingChangesEvenWhenPlaybackKeepsTheDisplayEqual() {
        let row = track()
        let playback = CatalogTrackContributions().replacing([row], from: .playback)
        #expect(playback.displayChangedURIs == [uri])
        #expect(playback.browsingInvalidatedURIs.isEmpty)
        #expect(playback.next.browsingTrack(for: uri) == nil)
        let browsing = playback.next.replacing([row], from: .playlist)
        #expect(browsing.displayChangedURIs.isEmpty)
        #expect(browsing.browsingInvalidatedURIs == [uri])
        let removed = browsing.next.replacing([], from: .playlist)
        #expect(removed.displayChangedURIs.isEmpty)
        #expect(removed.browsingInvalidatedURIs == [uri])
        #expect(removed.next.browsingTrack(for: uri) == nil)
        #expect(removed.next.displayTrack(for: uri)?.title == row.title)
    }

    @Test func partialSourceUpdatesRetainLinksWithoutBorrowingPlaybackAuthority() {
        let rich = track(links: "known")
        let partial = track(title: "Updated")
        var contributions = CatalogTrackContributions().replacing([rich], from: .playback).next
        contributions = contributions.replacing([partial], from: .playlist).next
        #expect(contributions.displayTrack(for: uri)?.title == partial.title)
        #expect(contributions.displayTrack(for: uri)?.artists == rich.artists)
        #expect(contributions.displayTrack(for: uri)?.albumItem == rich.albumItem)
        #expect(contributions.browsingTrack(for: uri)?.artists == [])
        #expect(contributions.browsingTrack(for: uri)?.albumItem == nil)
        contributions = contributions.replacing([rich], from: .album).next
        contributions = contributions.replacing([partial], from: .album).next
        #expect(contributions.browsingTrack(for: uri)?.artists == rich.artists)
        #expect(contributions.browsingTrack(for: uri)?.albumItem == rich.albumItem)
        let repeated = contributions.replacing([partial], from: .album)
        #expect(repeated.displayChangedURIs.isEmpty && repeated.browsingInvalidatedURIs.isEmpty)
    }

    @Test(arguments: ["same", "artist", "album"])
    func intermediateLabelsControlCrossSourceLinkLearning(change: String) {
        let rich = track(links: "low")
        let middle = track(
            artist: change == "artist" ? "Different artist" : "Artist",
            album: change == "album" ? "Different album" : "Album")
        var contributions = CatalogTrackContributions().replacing([rich], from: .search).next
        contributions = contributions.replacing([middle], from: .playlist).next
        contributions = contributions.replacing([track(title: "High")], from: .library).next
        for result in [contributions.displayTrack(for: uri), contributions.browsingTrack(for: uri)] {
            #expect(result?.title == "High")
            #expect(result?.artists == (change == "artist" ? [] : rich.artists))
            #expect(result?.albumItem == (change == "same" ? rich.albumItem : nil))
        }
        // Removing the intervening labels restores compatibility with the low source.
        contributions = contributions.replacing([], from: .playlist).next
        #expect(contributions.browsingTrack(for: uri)?.artists == rich.artists)
        #expect(contributions.browsingTrack(for: uri)?.albumItem == rich.albumItem)
    }

    @Test(arguments: [false, true])
    func lastDuplicateBorrowsOnlyFromThePreviousSnapshot(hasPrevious: Bool) {
        var contributions = CatalogTrackContributions()
        let old = track(links: "previous")
        if hasPrevious { contributions = contributions.replacing([old], from: .album).next }
        let replacement = contributions.replacing(
            [track(title: "First duplicate", links: "incoming"), track(title: "Last duplicate")], from: .album)
        let result = replacement.next.displayTrack(for: uri)
        #expect(result?.title == "Last duplicate")
        #expect(result?.artists == (hasPrevious ? old.artists : []))
        #expect(result?.albumItem == (hasPrevious ? old.albumItem : nil))
        #expect(replacement.displayChangedURIs == [uri])
    }

    @Test func occurrenceOnlyChangesDoNotInvalidateMetadata() {
        let first = CatalogTrack(
            id: "first-row", uri: uri, title: "Track", artist: "Artist", album: "Album", duration: 180,
            artworkURL: nil, addedAt: nil, occurrenceUID: "first-uid")
        let second = CatalogTrack(
            id: "second-row", uri: uri, title: first.title, artist: first.artist,
            album: first.album, duration: first.duration, artworkURL: nil,
            addedAt: Date(timeIntervalSince1970: 42), occurrenceUID: "second-uid")
        let original = CatalogTrackContributions().replacing([first], from: .playlist).next
        let replacement = original.replacing([second], from: .playlist)
        #expect(replacement.displayChangedURIs.isEmpty && replacement.browsingInvalidatedURIs.isEmpty)
        let playback = replacement.next.displayTrack(for: uri)?.playbackTrack
        #expect(playback?.id == uri && playback?.uri == uri)
        #expect(playback?.occurrenceUID == nil && playback?.addedAt == nil)
    }

    @Test func unchangedBrowsingPreservesThePlaybackContribution() {
        let library = track(title: "Library")
        var contributions = CatalogTrackContributions().replacing([library], from: .library).next
        contributions = contributions.replacing([library], from: .playback).next
        contributions = contributions.replacing([track(title: "Search")], from: .search).next
        let unchanged = contributions.replacing([library], from: .library)
        #expect(unchanged.displayChangedURIs.isEmpty && unchanged.browsingInvalidatedURIs.isEmpty)
        contributions = unchanged.next.replacing([], from: .search).next
        contributions = contributions.replacing([], from: .library).next
        #expect(contributions.displayTrack(for: uri)?.title == library.title)
        #expect(contributions.browsingTrack(for: uri) == nil)
    }

    @Test func replacementAndClearLeaveEarlierValuesIntact() {
        let original = CatalogTrackContributions().replacing([track(links: "known")], from: .library).next
        let replacement = original.replacing([track(title: "Changed")], from: .library)
        #expect(original.displayTrack(for: uri)?.title == "Track")
        #expect(replacement.next.displayTrack(for: uri)?.title == "Changed")
        let cleared = replacement.next.clearing()
        #expect(cleared.displayChangedURIs == [uri] && cleared.browsingInvalidatedURIs == [uri])
        #expect(cleared.next.displayTrack(for: uri) == nil && cleared.next.browsingTrack(for: uri) == nil)
        #expect(replacement.next.displayTrack(for: uri)?.artists.isEmpty == false)
        let newAccount = cleared.next.replacing([track()], from: .library).next
        #expect(newAccount.displayTrack(for: uri)?.artists == [])
        #expect(newAccount.displayTrack(for: uri)?.albumItem == nil)
    }

    @Test func browsingInvalidationIncludesTheWholeChangedSourceBatch() {
        let hiddenURI = "spotify:track:hidden"
        let hidden = track(uri: hiddenURI)
        let original = CatalogTrackContributions().replacing([hidden], from: .library).next
        let replacement = original.replacing([track(), track(uri: hiddenURI, title: "Fallback")], from: .search)
        #expect(replacement.displayChangedURIs == [uri])
        #expect(replacement.browsingInvalidatedURIs == [uri, hiddenURI])
        #expect(replacement.next.displayTrack(for: hiddenURI)?.title == hidden.title)
    }

    private func track(
        uri: String = "spotify:track:shared", title: String = "Track",
        artist: String = "Artist", album: String = "Album", links: String? = nil
    ) -> CatalogTrack {
        CatalogTrack(
            id: uri, uri: uri, title: title, artist: artist, album: album, duration: 180,
            artworkURL: nil, addedAt: nil,
            artists: links.map { [item($0, kind: .artist)] } ?? [],
            albumItem: links.map { item($0, kind: .album) })
    }

    private func item(_ id: String, kind: CatalogItem.Kind) -> CatalogItem {
        CatalogItem(
            id: id, uri: "spotify:\(kind.rawValue.lowercased()):\(id)", title: id,
            subtitle: "", artworkURL: nil, kind: kind)
    }
}
