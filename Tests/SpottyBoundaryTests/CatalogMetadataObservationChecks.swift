import Foundation
import Observation
import SpottyDomain
import Testing
@testable import SpottyCore

@Suite
@MainActor
struct CatalogMetadataObservationTests {
    private let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)

    private func makeMetadata() -> CatalogMetadataRepository {
        CatalogMetadataRepository(attributesProvider: HarnessTrackAttributes(), session: session)
    }

    private func observe(_ read: () -> Void) -> HarnessCounters {
        let counters = HarnessCounters()
        withObservationTracking(read) {
            counters.record("changes")
        }
        return counters
    }

    @Test
    func unrelatedAndUnchangedWritesLeaveTrackReadersAsleep() {
        let metadata = makeMetadata()
        let current = HarnessFixtures.track(uri: "spotify:track:current")
        let other = HarnessFixtures.track(uri: "spotify:track:other")
        metadata.replaceTracks([current], from: .library)
        metadata.retainTracks(from: .queue, for: [current.uri])

        // Each subscription is fresh: Observation callbacks are one-shot.
        let writes: [() -> Void] = [
            { metadata.replaceTracks([current], from: .library) },
            { metadata.cacheTracks([current], from: .library) },
            { metadata.retainTracks(from: .queue, for: [current.uri]) },
            { metadata.replaceTracks([], from: .queue) },
            { metadata.cacheTracks([other], from: .search) },
            { metadata.replaceTracks([other], from: .playlist) },
            { metadata.replaceTracks([], from: .playlist) },
            {
                metadata.replaceTracks(
                    [HarnessFixtures.track(uri: current.uri, title: "Provisional")], from: .nowPlaying)
            },
            { metadata.cacheItems([Self.item(other.uri)], from: .search) },
        ]
        for write in writes {
            let trackReader = observe { _ = metadata.knownTrack(for: current.uri) }
            let displayReader = observe { _ = metadata.displayInfo(for: current.uri) }
            write()
            #expect(trackReader.count("changes") == 0)
            #expect(displayReader.count("changes") == 0)
            #expect(metadata.knownTrack(for: current.uri) == current)
        }
    }

    @Test
    func absentLookupIgnoresOtherURIsButObservesFirstHydration() {
        let metadata = makeMetadata()
        let wanted = HarnessFixtures.track(uri: "spotify:track:wanted")
        let reader = observe { _ = metadata.knownTrack(for: wanted.uri) }
        metadata.cacheTracks([HarnessFixtures.track(uri: "spotify:track:other")], from: .search)
        #expect(reader.count("changes") == 0)
        metadata.cacheTracks([wanted], from: .queue)
        #expect(reader.count("changes") == 1)
        #expect(metadata.knownTrack(for: wanted.uri) == wanted)
    }

    @Test
    func effectiveChangesReachEveryReaderAndRemovalRevealsPrecedence() {
        let metadata = makeMetadata()
        let provisional = HarnessFixtures.track(uri: "spotify:track:current", title: "Provisional")
        let enriched = CatalogTrack(
            id: provisional.id, uri: provisional.uri, title: "Enriched", artist: "New artist",
            album: "New album", duration: 210, artworkURL: URL(string: "https://example.invalid/cover.jpg"),
            addedAt: HarnessDates.fixed, artists: [Self.item("spotify:artist:artist")]
        )
        metadata.replaceTracks([provisional], from: .nowPlaying)
        let nowPlayingReader = observe { _ = metadata.knownTrack(for: provisional.uri) }
        let queueReader = observe { _ = metadata.displayInfo(for: provisional.uri) }
        metadata.replaceTracks([enriched], from: .album)
        #expect(nowPlayingReader.count("changes") == 1)
        #expect(queueReader.count("changes") == 1)
        #expect(metadata.knownTrack(for: provisional.uri) == enriched)

        let fallbackReader = observe { _ = metadata.knownTrack(for: provisional.uri) }
        metadata.replaceTracks([], from: .album)
        #expect(fallbackReader.count("changes") == 1)
        #expect(metadata.knownTrack(for: provisional.uri) == provisional)
        let removalReader = observe { _ = metadata.knownTrack(for: provisional.uri) }
        metadata.replaceTracks([], from: .nowPlaying)
        #expect(removalReader.count("changes") == 1)
        #expect(metadata.knownTrack(for: provisional.uri) == nil)
    }

    @Test(arguments: ["title", "artist", "artwork"])
    func individualPresentationChangesPublish(field: String) {
        let metadata = makeMetadata()
        let track = HarnessFixtures.track(uri: "spotify:track:current")
        metadata.replaceTracks([track], from: .playlist)
        let reader = observe { _ = metadata.knownTrack(for: track.uri) }
        let changed = CatalogTrack(
            id: track.id, uri: track.uri, title: field == "title" ? "New title" : track.title,
            artist: field == "artist" ? "New artist" : track.artist, album: track.album, duration: track.duration,
            artworkURL: field == "artwork" ? URL(string: "https://example.invalid/cover.jpg") : nil, addedAt: nil
        )
        metadata.cacheTracks([changed], from: .playlist)
        #expect(reader.count("changes") == 1)
        #expect(metadata.knownTrack(for: track.uri) == changed)
    }

    @Test
    func suppressedSourceWritesRemainAvailableForFallback() {
        let metadata = makeMetadata()
        let preferred = HarnessFixtures.track(uri: "spotify:track:current", title: "Preferred")
        let fallback = HarnessFixtures.track(uri: preferred.uri, title: "Updated fallback")
        metadata.replaceTracks([preferred], from: .library)
        let reader = observe { _ = metadata.knownTrack(for: preferred.uri) }
        metadata.cacheTracks([fallback], from: .nowPlaying)
        #expect(reader.count("changes") == 0)
        metadata.replaceTracks([], from: .library)
        #expect(reader.count("changes") == 1)
        #expect(metadata.knownTrack(for: preferred.uri) == fallback)
    }

    @Test
    func retainedQueuePromotionOnlyPublishesEffectiveChanges() {
        let metadata = makeMetadata()
        let queued = HarnessFixtures.track(uri: "spotify:track:queued")
        metadata.retainTracks(from: .queue, for: [queued.uri])
        let hydrationReader = observe { _ = metadata.knownTrack(for: queued.uri) }
        metadata.replaceTracks([queued], from: .playlist)
        #expect(hydrationReader.count("changes") == 1)

        let retainedReader = observe { _ = metadata.knownTrack(for: queued.uri) }
        metadata.replaceTracks([], from: .playlist)
        metadata.replaceTracks([], from: .queue)
        #expect(retainedReader.count("changes") == 0)
        #expect(metadata.knownTrack(for: queued.uri) == queued)
        metadata.retainTracks(from: .queue, for: [])
        #expect(retainedReader.count("changes") == 1)
        #expect(metadata.knownTrack(for: queued.uri) == nil)
    }

    @Test
    func itemReadersObserveOnlyEffectiveChangesForTheirURI() {
        let metadata = makeMetadata()
        let item = Self.item("spotify:playlist:wanted")
        let fallback = Self.item(item.uri, title: "Fallback")
        metadata.replaceItems([item], from: .search)
        let writes: [() -> Void] = [
            { metadata.replaceItems([item], from: .search) },
            { metadata.cacheItems([item], from: .search) },
            { metadata.cacheItems([Self.item("spotify:playlist:other")], from: .home) },
            { metadata.replaceItems([fallback], from: .library) },
            { metadata.cacheTracks([HarnessFixtures.track(uri: item.uri)], from: .search) },
        ]
        for write in writes {
            let reader = observe { _ = metadata.knownItem(for: item.uri) }
            write()
            #expect(reader.count("changes") == 0)
        }
        let reader = observe { _ = metadata.knownItem(for: item.uri) }
        metadata.replaceItems([], from: .search)
        #expect(reader.count("changes") == 1)
        #expect(metadata.knownItem(for: item.uri) == fallback)
    }

    @Test
    func displayFallbackObservesUnknownToItemToTrackAndBack() {
        let metadata = makeMetadata()
        let uri = "spotify:track:wanted"
        let item = Self.item(uri)
        let track = HarnessFixtures.track(uri: uri)
        let writes: [() -> Void] = [
            { metadata.cacheItems([item], from: .home) },
            { metadata.cacheTracks([track], from: .search) },
            { metadata.replaceTracks([], from: .search) },
            { metadata.replaceItems([], from: .home) },
        ]
        let expectedTitles = [item.title, track.title, item.title, "Unknown track"]
        for (write, title) in zip(writes, expectedTitles) {
            let reader = observe { _ = metadata.displayInfo(for: uri) }
            write()
            #expect(reader.count("changes") == 1)
            #expect(metadata.displayInfo(for: uri).title == title)
        }
    }

    @Test(arguments: [false, true])
    func resetInvalidatesKnownContentAndAllowsRehydration(changeAccount: Bool) {
        let metadata = makeMetadata()
        let track = HarnessFixtures.track(uri: "spotify:track:current")
        let item = Self.item("spotify:playlist:current")
        metadata.replaceTracks([track], from: .library)
        metadata.replaceItems([item], from: .home)
        metadata.retainTracks(from: .queue, for: [track.uri])
        let trackReader = observe { _ = metadata.knownTrack(for: track.uri) }
        let itemReader = observe { _ = metadata.knownItem(for: item.uri) }
        if changeAccount { session.update(accountEpoch: 2, isAvailable: true) }
        metadata.reset()
        #expect(trackReader.count("changes") == 1)
        #expect(itemReader.count("changes") == 1)
        #expect(metadata.knownTrack(for: track.uri) == nil)
        #expect(metadata.knownItem(for: item.uri) == nil)

        let hydrationReader = observe { _ = metadata.knownTrack(for: track.uri) }
        metadata.replaceTracks([track], from: .playlist)
        #expect(hydrationReader.count("changes") == 1)
        metadata.replaceTracks([], from: .playlist)
        #expect(metadata.knownTrack(for: track.uri) == nil, "reset also releases retained queue metadata")
    }

    @Test
    func firstWriteInNewAccountInvalidatesOldContentWithoutLeakingIt() {
        let metadata = makeMetadata()
        let track = HarnessFixtures.track(uri: "spotify:track:old")
        let item = Self.item("spotify:playlist:old")
        metadata.replaceTracks([track], from: .library)
        metadata.replaceItems([item], from: .home)
        let trackReader = observe { _ = metadata.knownTrack(for: track.uri) }
        let itemReader = observe { _ = metadata.knownItem(for: item.uri) }
        session.update(accountEpoch: 2, isAvailable: true)
        #expect(metadata.knownTrack(for: track.uri) == nil)
        metadata.cacheTracks([HarnessFixtures.track(uri: "spotify:track:new")], from: .search)
        #expect(trackReader.count("changes") == 1)
        #expect(itemReader.count("changes") == 1)
        #expect(metadata.knownTrack(for: track.uri) == nil)
        #expect(metadata.knownItem(for: item.uri) == nil)

        session.update(accountEpoch: 2, isAvailable: false)
        metadata.cacheTracks([track], from: .library)
        #expect(metadata.knownTrack(for: track.uri) == nil)
    }

    private static func item(_ uri: String, title: String = "Item") -> CatalogItem {
        CatalogItem(id: uri, uri: uri, title: title, subtitle: "Subtitle", artworkURL: nil, kind: .playlist)
    }
}
