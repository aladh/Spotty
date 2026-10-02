@testable import SpottyRuntimeTestSupport
import SpottyTestSupport
import Foundation
import SpottyDomain
import SpottyRuntimeContracts
@testable import SpottySessionRuntime
import Testing
@testable import SpottyCore

@MainActor
struct CatalogDetailExpiryChecks {
    @Test(
        arguments: ["album", "overview", "discography"],
        [299.0, 300.0, 301.0, -1.0].flatMap { elapsed in
            [false, true].map { (elapsed, $0) }
        })
    func revisitsExpireAtFiveMinutesWithoutDiscardingSuccessfulRows(
        name: String, sample: (Double, Bool)
    ) async {
        let (elapsed, empty) = sample
        let provider = HarnessCatalog()
        Self.configure(provider, rows: empty ? 0 : 1)
        let clock = HarnessClock.sticky()
        let detail = makeDetail(name, provider: provider, clock: clock)
        let first = Self.item(name, "first")
        await detail.load(first)
        let version =
            name == "album" ? detail.albumContent.collection.version : detail.artistContent.popularTracks.version
        await detail.load(Self.item(name, "second"))
        clock.set(now: HarnessDates.fixed.addingTimeInterval(elapsed))
        detail.prepare(first)
        #expect(detail.hasLoadedContent)
        #expect(rows(detail, name: name) == (empty ? 0 : 1))
        #expect(
            (name == "album" ? detail.albumContent.collection.version : detail.artistContent.popularTracks.version)
                == version)
        let expired = elapsed < 0 || elapsed >= 300
        #expect(detail.isShowingCachedContent == expired)
        await detail.load(first)
        #expect(requests(provider, name: name) == (expired ? 3 : 2))
        #expect(detail.isCurrentContent)
    }

    @Test(arguments: ["album", "overview", "discography"], [299.0, 300.0, -1.0])
    func repeatedSelectedReadsUseTheSameExpiryPolicy(name: String, elapsed: Double) async {
        let provider = HarnessCatalog()
        Self.configure(provider, rows: 1)
        let clock = HarnessClock.sticky()
        let detail = makeDetail(name, provider: provider, clock: clock)
        let selected = Self.item(name, "first")
        await detail.load(selected)
        clock.set(now: HarnessDates.fixed.addingTimeInterval(elapsed))
        await detail.load(selected)
        #expect(requests(provider, name: name) == (elapsed < 0 || elapsed >= 300 ? 2 : 1))
    }

    @Test func metadataDoesNotRenewTheAcceptedCollectionTime() async {
        let provider = HarnessCatalog()
        Self.configure(provider, rows: 1)
        let clock = HarnessClock.sticky()
        let detail = makeDetail("album", provider: provider, clock: clock)
        let first = Self.item("album", "first")
        await detail.load(first)
        await detail.load(Self.item("album", "second"))
        clock.advance(seconds: 299)
        let uri = "spotify:track:first-0"
        let update = CatalogTrackMetadata(track: HarnessFixtures.track(uri: uri, title: "Enriched"), requestedURI: uri)
        _ = detail.applyEntityMetadata([uri: update])
        clock.advance(seconds: 1)
        detail.prepare(first)
        #expect(detail.albumContent.collection.tracks.first?.title == "Enriched")
        #expect(detail.isShowingCachedContent)
        await detail.load(first)
        #expect(provider.albumRequestCount == 3)
    }

    @Test(arguments: ["album", "overview", "discography"])
    func expiredRefreshKeepsRowsAndSharesItsFlight(name: String) async throws {
        let provider = HarnessCatalog()
        Self.configure(provider, rows: 1)
        let clock = HarnessClock.sticky()
        let detail = makeDetail(name, provider: provider, clock: clock)
        let selected = Self.item(name, "first")
        await detail.load(selected)
        let gate = HarnessResponseGate<Void>(cancellation: .ignored)
        defer { gate.close() }
        provider.onAlbum = { id in
            try await gate.wait()
            return Self.album(id, rows: 2)
        }
        provider.onArtist = { id in
            try await gate.wait()
            return Self.artist(id, rows: 2)
        }
        provider.onArtistDiscography = provider.onArtist
        clock.advance(seconds: 300)
        let original = Task.immediate { await detail.load(selected) }
        defer { original.cancel() }
        try await requireEventually(description: "One expired-detail refresh admitted") { gate.waiterCount == 1 }
        #expect(detail.isLoading && detail.isShowingCachedContent)
        #expect(rows(detail, name: name) == 1)
        let joined = Task.immediate { await detail.load(selected) }
        defer { joined.cancel() }
        #expect(requests(provider, name: name) == 2)
        gate.finish(())
        await original.value
        await joined.value
        #expect(rows(detail, name: name) == 2)
        #expect(detail.isCurrentContent && !detail.isLoading)
        #expect(requests(provider, name: name) == 2)
    }

    @Test(arguments: ["overview", "discography"])
    func largeArtistPayloadsEnforceTheTotalRetentionBudget(name: String) async {
        let provider = HarnessCatalog()
        Self.configure(provider, rows: 8_000)
        let detail = makeDetail(name, provider: provider, clock: HarnessClock.sticky())
        await detail.load(Self.item(name, "first"))
        await detail.load(Self.item(name, "second"))
        await detail.load(Self.item(name, "third"))
        detail.prepare(Self.item(name, "first"))
        #expect(rows(detail, name: name) == 0 && !detail.hasLoadedContent)
        detail.prepare(Self.item(name, "second"))
        #expect(rows(detail, name: name) == 8_000 && detail.isCurrentContent)
        await detail.load(Self.item(name, "second"))
        #expect(requests(provider, name: name) == 3)
        await detail.load(Self.item(name, "first"))
        #expect(requests(provider, name: name) == 4)
    }

    @Test func oversizedActiveContentExpiresEvenWithoutARetainedEntry() async {
        let provider = HarnessCatalog()
        Self.configure(provider, rows: 20_001)
        let clock = HarnessClock.sticky()
        let detail = makeDetail("discography", provider: provider, clock: clock)
        let selected = Self.item("discography", "first")
        await detail.load(selected)
        clock.advance(seconds: 299)
        await detail.load(selected)
        #expect(provider.discographyRequestCount == 1)
        clock.advance(seconds: 1)
        await detail.load(selected)
        #expect(provider.discographyRequestCount == 2)
        detail.prepare(Self.item("discography", "second"))
        detail.prepare(selected)
        #expect(!detail.hasLoadedContent && detail.artistContent.releases.isEmpty)
    }

    @Test func compositionForwardsTheClockThroughDiscographyChildren() async {
        let provider = HarnessCatalog()
        Self.configure(provider, rows: 1)
        let clock = HarnessClock.sticky()
        let session = CatalogSessionAvailability(isAvailable: true)
        let environment = HarnessEnvironment.make(clock: clock)
        let catalog = CatalogStore(
            provider: provider, playlistMutations: environment.playlistMutations,
            session: session, clock: clock, feedback: TransientFeedbackPresenter(clock: clock))
        let album = Self.item("album", "album")
        let artist = Self.item("overview", "artist")
        let child = Self.item("album", "child")
        catalog.discographyStore.prepare(artistURI: artist.uri)
        for elapsed in [0.0, 299.0, 300.0] {
            clock.set(now: HarnessDates.fixed.addingTimeInterval(elapsed))
            await catalog.albumStore.load(album)
            await catalog.artistStore.load(artist)
            await catalog.discographyStore.artist.load(artist)
            await catalog.discographyStore.load(child, artistURI: artist.uri)
            #expect(provider.albumRequestCount == (elapsed < 300 ? 2 : 4))
            #expect(provider.artistRequestCount == (elapsed < 300 ? 1 : 2))
            #expect(provider.discographyRequestCount == (elapsed < 300 ? 1 : 2))
        }
    }

    @Test(arguments: ["album", "overview", "discography"], ["cancel", "account"])
    func expiredLateRefreshCannotRenewRetiredContent(name: String, boundary: String) async throws {
        let provider = HarnessCatalog()
        Self.configure(provider, rows: 1)
        let clock = HarnessClock.sticky()
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let kind: CatalogDetailKind =
            name == "album" ? .album : name == "overview" ? .artistOverview : .artistDiscography
        let detail = CatalogDetailCoordinator(kind: kind, provider: provider, session: session, clock: clock)
        let selected = Self.item(name, "first")
        await detail.load(selected)
        let gate = HarnessResponseGate<Void>(cancellation: .ignored)
        defer { gate.close() }
        provider.onAlbum = { id in
            try await gate.wait()
            return Self.album(id, rows: 2)
        }
        provider.onArtist = { id in
            try await gate.wait()
            return Self.artist(id, rows: 2)
        }
        provider.onArtistDiscography = provider.onArtist
        clock.advance(seconds: 300)
        let refresh = Task.immediate { await detail.load(selected) }
        defer { refresh.cancel() }
        try await requireEventually(description: "Expired refresh held before retirement") { gate.waiterCount == 1 }
        let workers = detail.workerSettlements()
        try #require(workers.count == 1)
        if boundary == "cancel" {
            refresh.cancel()
        } else {
            session.update(accountEpoch: 2, isAvailable: true)
            detail.prepare(selected)
        }
        gate.finish(())
        await refresh.value
        for worker in workers { await worker.value }
        #expect(rows(detail, name: name) == (boundary == "cancel" ? 1 : 0))
        #expect(!detail.isCurrentContent)
        Self.configure(provider, rows: 3)
        await detail.load(selected)
        #expect(rows(detail, name: name) == 3 && detail.isCurrentContent)
        #expect(requests(provider, name: name) == 3)
        clock.advance(seconds: 299)
        await detail.load(selected)
        #expect(requests(provider, name: name) == 3)
        clock.advance(seconds: 1)
        await detail.load(selected)
        #expect(requests(provider, name: name) == 4)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPOTTY_DETAIL_REVISIT_REPORT"] != nil))
    func recordSyntheticRevisitComparison() async throws {
        #if DEBUG && SPOTTY_BROWSING_OPTIMIZED
            let path = try #require(ProcessInfo.processInfo.environment["SPOTTY_DETAIL_REVISIT_REPORT"])
            try #require(path.hasPrefix("/") && !FileManager.default.fileExists(atPath: path))
            var samples: [[String: Any]] = []
            let timer = ContinuousClock()
            for name in ["album", "overview", "discography"] {
                for wave in 0..<5 {
                    for freshOwner in [false, true] {
                        let provider = HarnessCatalog()
                        Self.configure(provider, rows: 10)
                        let detail = makeDetail(name, provider: provider, clock: HarnessClock.sticky())
                        let first = Self.item(name, "first")
                        await detail.load(first)
                        await detail.load(Self.item(name, "second"))
                        let revisit =
                            freshOwner
                            ? makeDetail(name, provider: provider, clock: HarnessClock.sticky()) : detail
                        let start = timer.now
                        revisit.prepare(first)
                        let restored = timer.now - start
                        let readyAtPrepare = rows(revisit, name: name) == 10 && revisit.isCurrentContent
                        try #require(readyAtPrepare == !freshOwner)
                        await revisit.load(first)
                        let complete = timer.now - start
                        let count = requests(provider, name: name)
                        try #require(count == (freshOwner ? 3 : 2))
                        samples.append([
                            "kind": name, "wave": wave, "freshOwnerControl": freshOwner,
                            "providerCalls": count, "visibleRows": rows(revisit, name: name),
                            "usableAtPrepare": readyAtPrepare,
                            "prepareSeconds": Self.seconds(restored),
                            "usableRevisitSeconds": Self.seconds(readyAtPrepare ? restored : complete),
                            "revisitLoadCompletedSeconds": Self.seconds(complete),
                        ])
                    }
                }
            }
            let report: [String: Any] = [
                "version": 1, "samples": samples, "retentionRouteLimit": 20,
                "retentionRowCostLimit": 20_000, "expirySeconds": 300,
                "buildProfile": "optimized-debug-native-nonwmo", "shippingBuild": false,
                "limits":
                    "Immediate synthetic providers; a new coordinator on the third visit is a current-code no-retention control, not a historical build. Timings cover MainActor prepare/load completion, not native first-frame or network latency. Ten rows per route; row-cost budget is separate from byte footprint. No app, playback or memory-byte reduction claim.",
            ]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
        #else
            Issue.record("Revisit probe requires verified optimized Debug native/non-WMO flags")
        #endif
    }

    private nonisolated static func seconds(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }

    private func makeDetail(_ name: String, provider: HarnessCatalog, clock: HarnessClock) -> CatalogDetailCoordinator {
        let kind: CatalogDetailKind =
            name == "album" ? .album : name == "overview" ? .artistOverview : .artistDiscography
        return CatalogDetailCoordinator(
            kind: kind, provider: provider, session: CatalogSessionAvailability(isAvailable: true), clock: clock)
    }

    private func rows(_ detail: CatalogDetailCoordinator, name: String) -> Int {
        name == "album" ? detail.albumContent.collection.tracks.count : detail.artistContent.releases.count
    }

    private func requests(_ provider: HarnessCatalog, name: String) -> Int {
        name == "album"
            ? provider.albumRequestCount
            : name == "overview" ? provider.artistRequestCount : provider.discographyRequestCount
    }

    private nonisolated static func item(_ name: String, _ id: String) -> CatalogItem {
        let kind: CatalogItem.Kind = name == "album" ? .album : .artist
        return CatalogItem(
            id: id, uri: "spotify:\(kind.rawValue.lowercased()):\(id)", title: id, subtitle: "", artworkURL: nil,
            kind: kind)
    }

    private nonisolated static func album(_ id: String, rows: Int) -> CatalogAlbumSnapshot {
        CatalogAlbumSnapshot(
            tracks: (0..<rows).map { HarnessFixtures.track(uri: "spotify:track:\(id)-\($0)") }, releaseDate: "2026")
    }

    private nonisolated static func artist(_ id: String, rows: Int) -> CatalogArtistSnapshot {
        CatalogArtistSnapshot(
            name: id,
            releases: (0..<rows).map {
                CatalogItem(
                    id: "\(id)-\($0)", uri: "spotify:album:\(id)-\($0)", title: "Synthetic album", subtitle: "",
                    artworkURL: nil, kind: .album)
            })
    }

    private nonisolated static func configure(_ provider: HarnessCatalog, rows: Int) {
        provider.onAlbum = { Self.album($0, rows: rows) }
        provider.onArtist = { Self.artist($0, rows: rows) }
        provider.onArtistDiscography = provider.onArtist
    }
}
