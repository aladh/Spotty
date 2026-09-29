@testable import SpottyRuntimeTestSupport
import SpottyTestSupport
import SpottyDomain
import SpottyRuntimeContracts
import Testing
@testable import SpottyCore

@Suite("Playlist query ownership")
@MainActor
struct PlaylistQueryOwnerTests {
    @Test
    func cancellingTheOriginalCallerPreservesTheJoinedCachedAndLiveLoad() async throws {
        let live = HarnessResponseGate<CatalogPlaylistSnapshot>(cancellation: .ignored)
        defer { live.close() }
        let provider = HarnessCatalog()
        let saved = snapshot("Saved", freshness: .cached(fetchedAt: HarnessDates.fixed))
        provider.onCachedPlaylist = { _ in saved }
        provider.onPlaylist = { _ in try await live.wait() }
        let session = CatalogSessionAvailability(isAvailable: true)
        let store = PlaylistStore(
            provider: provider, metadata: CatalogMetadataRepository(session: session), session: session)
        defer { store.reset() }
        let completed = HarnessCounters()
        let selected = item("first")
        let original = Task.immediate {
            defer { completed.record("original") }
            await store.load(selected)
        }
        defer { original.cancel() }
        try await requireEventually { live.waiterCount == 1 && store.description == "Saved" }
        let joined = Task.immediate {
            defer { completed.record("joined") }
            await store.load(selected)
        }
        defer { joined.cancel() }
        original.cancel()

        try await requireEventually { completed.count("original") == 1 }
        #expect(completed.count("joined") == 0)
        #expect(store.isLoading)
        #expect(store.isShowingCachedContent)
        #expect(!store.canEditLoadedContent)
        #expect(provider.count("cachedPlaylist") == 1 && provider.playlistRequestCount == 1)
        let current = snapshot("Live")
        live.finish(current)
        await joined.value

        #expect(store.description == "Live")
        #expect(!store.isLoading && store.canEditLoadedContent)
        #expect(store.tracks.map(\.id) == saved.tracks.map(\.id))
        #expect(store.tracks.map(\.occurrenceUID) == ["server-a", "server-b"])
        #expect(store.tracks.map(\.uri) == ["spotify:track:duplicate", "spotify:track:duplicate"])
    }

    @Test
    func finalCancellationSettlesLoadingAndFencesTheReplyFromItsReplacement() async throws {
        let old = HarnessResponseGate<CatalogPlaylistSnapshot>(cancellation: .ignored)
        let replacement = HarnessResponseGate<CatalogPlaylistSnapshot>(cancellation: .ignored)
        defer { old.close(); replacement.close() }
        let completed = HarnessCounters()
        let provider = HarnessCatalog()
        provider.onPlaylist = { _ in
            if old.requestCount == 0 {
                defer { completed.record("oldSource") }
                return try await old.wait()
            }
            return try await replacement.wait()
        }
        let session = CatalogSessionAvailability(isAvailable: true)
        let store = PlaylistStore(
            provider: provider, metadata: CatalogMetadataRepository(session: session), session: session)
        defer { store.reset() }
        let selected = item("first")
        let cancelled = Task.immediate {
            defer { completed.record("cancelledCaller") }
            await store.load(selected)
        }
        defer { cancelled.cancel() }
        try await requireEventually { old.waiterCount == 1 }
        cancelled.cancel()
        try await requireEventually { completed.count("cancelledCaller") == 1 }
        #expect(!store.isLoading)
        #expect(old.waiterCount == 1)
        #expect(store.tracks.isEmpty)

        let fresh = Task.immediate { await store.load(selected) }
        defer { fresh.cancel() }
        try await requireEventually { replacement.waiterCount == 1 }
        #expect(store.isLoading)
        old.finish(snapshot("Forbidden old"))
        try await requireEventually { completed.count("oldSource") == 1 }
        #expect(store.tracks.isEmpty, "the cancelled source cannot publish while its replacement is parked")
        #expect(store.description.isEmpty)
        #expect(store.isLoading, "the cancelled source cannot settle its replacement")
        replacement.finish(snapshot("Replacement"))
        await fresh.value

        #expect(provider.playlistRequestCount == 2)
        #expect(store.description == "Replacement")
        #expect(!store.isLoading && store.canEditLoadedContent)
        let version = store.trackCollection.version
        store.prepare(item("other"))
        store.prepare(selected)
        #expect(store.description == "Replacement")
        #expect(store.trackCollection.version == version)
        await store.load(selected)
        #expect(provider.playlistRequestCount == 2)
    }

    private func item(_ id: String) -> CatalogItem {
        CatalogItem(
            id: id, uri: "spotify:playlist:\(id)", title: id, subtitle: "", artworkURL: nil,
            kind: .playlist)
    }

    private func snapshot(_ title: String, freshness: CatalogFreshness = .current) -> CatalogPlaylistSnapshot {
        let tracks = ["a", "b"].map { suffix in
            CatalogTrack(
                id: "display-\(suffix)", uri: "spotify:track:duplicate", title: title,
                artist: "Artist", album: "Album", duration: 100, artworkURL: nil,
                addedAt: HarnessDates.fixed, occurrenceUID: "server-\(suffix)")
        }
        return CatalogPlaylistSnapshot(
            description: title, ownerURI: "spotify:user:owner", tracks: tracks, freshness: freshness)
    }
}
