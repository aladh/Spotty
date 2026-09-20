import Foundation
import SpottyDomain
import SpottyRuntimeContracts
import Testing
@testable import SpottyCore

@Suite("Shared catalog load contract")
@MainActor
struct CatalogLoadContractChecks {
    @Test(arguments: [false, true])
    func cancelledRefreshNeverRestoresCurrentAuthority(saved: Bool) {
        let session = CatalogSessionAvailability(isAvailable: true)
        var state = CatalogLoadState()
        state.receive(session: session.snapshot, freshness: saved ? .cached(fetchedAt: HarnessDates.fixed) : .current)
        #expect(state.isCurrent(in: session.snapshot) == !saved)
        state.begin()
        #expect(state.isLoading && state.hasContent)
        #expect(!state.isCurrent(in: session.snapshot))
        state.finish()  // Cancelled reads finish without publishing or inventing an error.
        #expect(!state.isLoading && state.error == nil)
        #expect(state.isShowingSavedContent(in: session.snapshot))
        state.begin()
        state.receive(session: session.snapshot)
        #expect(!state.isCurrent(in: session.snapshot), "receiving saved or live data does not finish a request")
        state.finish()
        #expect(state.isCurrent(in: session.snapshot))
        session.update(accountEpoch: 1, isAvailable: false)
        session.update(accountEpoch: 1, isAvailable: true)
        #expect(!state.isCurrent(in: session.snapshot), "reconnect requires new proof")
    }

    @Test(arguments: ["playlist", "album", "artist", "discography"], [false, true])
    func detailStoresRetainTransientFailuresAndRetireCredentialRefusals(surface: String, empty: Bool) async {
        let provider = HarnessCatalog()
        let tracks = empty ? [] : [HarnessFixtures.track(uri: "spotify:track:kept")]
        let releases = empty ? [] : [item("release", kind: .album)]
        provider.onPlaylistSnapshot = { _ in .init(description: "Kept", ownerURI: nil, tracks: tracks) }
        provider.onAlbumSnapshot = { _ in .init(tracks: tracks, releaseDate: "2026") }
        provider.onArtistSnapshot = { _ in .init(name: "Artist", releases: releases) }
        provider.onArtistDiscographySnapshot = provider.onArtistSnapshot
        let session = CatalogSessionAvailability(isAvailable: true)
        let adapter = detail(surface, provider: provider, session: session)
        await adapter.load(false)
        let expected = empty ? 0 : 1
        #expect(adapter.count() == expected && !adapter.saved() && adapter.error() == nil)
        for failure in [CatalogReadFailure.offline, .timedOut, .throttled, .compatibility, .sessionExpired] {
            provider.onPlaylistSnapshot = { _ in throw failure }
            provider.onAlbumSnapshot = { _ in throw failure }
            provider.onArtistSnapshot = { _ in throw failure }
            provider.onArtistDiscographySnapshot = { _ in throw failure }
            await adapter.load(true)
            #expect(adapter.error() != nil)
            #expect(adapter.count() == (failure == .sessionExpired ? 0 : expected))
            #expect(adapter.saved() == (failure != .sessionExpired))
        }
    }

    @Test func libraryRefusalRetiresEverySectionAndFencesALateSibling() async throws {
        let provider = HarnessCatalog()
        let playlist = item("kept", kind: .playlist)
        provider.onPlaylistLibrary = { [PlaylistLibraryNode(playlist: playlist)] }
        let session = CatalogSessionAvailability(isAvailable: true)
        let metadata = CatalogMetadataRepository(session: session)
        let store = HomeLibraryStore(provider: provider, metadata: metadata, session: session)
        await store.loadPlaylists()
        #expect(store.playlists == [playlist])
        let gate = CatalogLateResponse()
        provider.onPlaylistLibrary = {
            await gate.wait()
            return [PlaylistLibraryNode(playlist: playlist)]
        }
        let late = Task { await store.loadPlaylists(force: true) }
        #expect(await waitUntil { await gate.isWaiting })
        provider.onLibraryAlbums = { throw CatalogReadFailure.sessionExpired }
        await store.loadAlbums()
        #expect(store.playlists.isEmpty && store.loadedSections.isEmpty && !store.isLoading)
        #expect(store.errors.count == HomeLibraryStore.Section.allCases.count)
        await gate.finish()
        await late.value
        #expect(store.playlists.isEmpty && store.loadedSections.isEmpty)
        #expect(store.errors.count == HomeLibraryStore.Section.allCases.count)
        provider.onPlaylistLibrary = { [] }
        await store.loadPlaylists()
        #expect(store.loadedSections.contains(.playlists), "a fresh successful empty result clears the refusal")
        #expect(store.error(for: .playlists) == nil)
    }

    @Test func cancelledRefreshStaysStaleAcrossRouteRevisits() async throws {
        let provider = HarnessCatalog()
        provider.onPlaylistSnapshot = { _ in .init(description: "Kept", ownerURI: nil, tracks: []) }
        let session = CatalogSessionAvailability(isAvailable: true)
        let store = PlaylistStore(
            provider: provider, metadata: CatalogMetadataRepository(session: session), session: session)
        let selected = item("fixture", kind: .playlist)
        await store.load(selected)
        #expect(store.canEditLoadedContent)
        let gate = HarnessClock.parked()
        provider.onPlaylistSnapshot = { _ in
            try await gate.sleep(seconds: 1)
            throw CatalogReadFailure.offline
        }
        let refresh = Task { await store.load(selected, force: true) }
        try await requireEventually { gate.waiterCount == 1 }
        refresh.cancel()
        await refresh.value
        #expect(!store.canEditLoadedContent && store.error == nil)
        store.prepare(item("other", kind: .playlist))
        store.prepare(selected)
        #expect(store.isShowingCachedContent && !store.canEditLoadedContent)
        provider.onPlaylistSnapshot = { _ in .init(description: "Fresh", ownerURI: nil, tracks: []) }
        await store.load(selected)
        #expect(store.description == "Fresh" && store.canEditLoadedContent)
    }

    private func item(_ id: String, kind: CatalogItem.Kind) -> CatalogItem {
        CatalogItem(
            id: id, uri: "spotify:\(kind.rawValue.lowercased()):\(id)", title: id, subtitle: "", artworkURL: nil,
            kind: kind)
    }

    private struct Detail {
        let load: (Bool) async -> Void
        let count: () -> Int
        let saved: () -> Bool
        let error: () -> String?
    }

    private func detail(_ surface: String, provider: HarnessCatalog, session: CatalogSessionAvailability) -> Detail {
        let metadata = CatalogMetadataRepository(session: session)
        switch surface {
        case "playlist":
            let store = PlaylistStore(provider: provider, metadata: metadata, session: session)
            return Detail(
                load: { await store.load(item("fixture", kind: .playlist), force: $0) }, count: { store.tracks.count },
                saved: { store.isShowingCachedContent }, error: { store.error })
        case "album":
            let store = AlbumDetailStore(provider: provider, metadata: metadata, session: session)
            return Detail(
                load: { await store.load(item("fixture", kind: .album), force: $0) }, count: { store.tracks.count },
                saved: { store.isShowingCachedContent }, error: { store.error })
        default:
            let store = ArtistDetailStore(
                provider: provider, session: session, content: surface == "artist" ? .overview : .discography)
            return Detail(
                load: { await store.load(item("fixture", kind: .artist), force: $0) }, count: { store.releases.count },
                saved: { store.isShowingCachedContent }, error: { store.error })
        }
    }
}

/// A suspension gate, not another catalog fake: deliberately ignores cancellation to test late publication.
private actor CatalogLateResponse {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func finish() { continuation?.resume(); continuation = nil }
}
