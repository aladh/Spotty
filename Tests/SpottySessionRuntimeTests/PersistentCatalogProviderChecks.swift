import Foundation
import SpottyCatalogStorage
import SpottyDomain
import SpottyRuntimeContracts
import Testing
@testable import SpottySessionRuntime

struct PersistentCatalogProviderTests {
    @Test func inactiveProviderRejectsReadsBeforeCallingTheGateway() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = CatalogProviderSource()
        let provider = PersistentCatalogProvider(source: source, rootDirectory: root)
        await #expect(throws: CatalogReadFailure.sessionExpired) { try await provider.profile() }
        await #expect(throws: CatalogReadFailure.sessionExpired) { try await provider.playlist(id: "one") }
        #expect(await source.profileCalls == 0)
        #expect(await source.playlistCalls == 0)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func cachedRoutesRequireFreshAccountProofAfterReopen() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let tracks = [track("one"), track("one", occurrence: "duplicate"), track("two")]
        let playlist = playlist(tracks)
        let album = CatalogAlbumSnapshot(tracks: tracks, releaseDate: "2026-09-01")
        let source = CatalogProviderSource(playlist: .success(playlist), album: .success(album))
        let original = PersistentCatalogProvider(source: source, rootDirectory: root, clock: ProviderClock())
        await original.activate()
        _ = try await original.profile()
        #expect(try await original.playlist(id: "one") == playlist)
        #expect(try await original.album(id: "one") == album)
        #expect(await original.retire(purge: false))

        let offline = CatalogProviderSource()
        let reopened = PersistentCatalogProvider(source: offline, rootDirectory: root)
        await reopened.activate()
        // A disk partition is not evidence that this process holds that account's grant.
        await #expect(throws: CatalogReadFailure.offline) { try await reopened.playlist(id: "one") }
        _ = try await reopened.profile()
        let cachedPlaylist = try await reopened.playlist(id: "one")
        #expect(cachedPlaylist.tracks == tracks)
        #expect(cachedPlaylist.description == playlist.description)
        #expect(cachedPlaylist.freshness == .cached(fetchedAt: ProviderClock.instant))
        #expect(cachedPlaylist.ownerURI == nil)
        #expect(cachedPlaylist.item?.ownerURI == nil)
        #expect(cachedPlaylist.item?.title == playlist.item?.title)
        let cachedAlbum = try await reopened.album(id: "one")
        #expect(cachedAlbum.tracks == tracks)
        #expect(cachedAlbum.releaseDate == album.releaseDate)
        #expect(cachedAlbum.freshness == .cached(fetchedAt: ProviderClock.instant))
        #expect(await reopened.retire(purge: true))
    }

    @Test func verifiedAccountsCannotReadEachOthersRetainedRoutes() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let accountA = CatalogProviderSource(playlist: .success(playlist([track("account-a-only")])))
        let first = PersistentCatalogProvider(source: accountA, rootDirectory: root)
        await first.activate()
        _ = try await first.profile()
        _ = try await first.playlist(id: "one")
        #expect(await first.retire(purge: false))

        let accountB = CatalogProviderSource(profile: CatalogProfileSnapshot(name: "B", uri: "spotify:user:account-b"))
        let second = PersistentCatalogProvider(source: accountB, rootDirectory: root)
        await second.activate()
        _ = try await second.profile()
        await #expect(throws: CatalogReadFailure.offline) { try await second.playlist(id: "one") }
        #expect(await second.retire(purge: false))

        let sameAccount = PersistentCatalogProvider(source: CatalogProviderSource(), rootDirectory: root)
        await sameAccount.activate()
        _ = try await sameAccount.profile()
        #expect(try await sameAccount.playlist(id: "one").tracks == [track("account-a-only")])
        #expect(await sameAccount.retire(purge: true))
    }

    @Test func coldLogoutPurgesRetainedContentBeforeAnyProfileProof() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = PersistentCatalogProvider(
            source: CatalogProviderSource(playlist: .success(playlist([track("retained")]))), rootDirectory: root
        )
        await original.activate()
        _ = try await original.profile()
        _ = try await original.playlist(id: "one")
        #expect(await original.retire(purge: false))

        let coldSource = CatalogProviderSource()
        let cold = PersistentCatalogProvider(source: coldSource, rootDirectory: root)
        #expect(await cold.retire(purge: true))
        #expect(await coldSource.profileCalls == 0)

        let reopened = PersistentCatalogProvider(source: CatalogProviderSource(), rootDirectory: root)
        await reopened.activate()
        _ = try await reopened.profile()
        await #expect(throws: CatalogReadFailure.offline) { try await reopened.playlist(id: "one") }
        #expect(await reopened.retire(purge: true))
    }

    @Test func cachedPaginationPreservesTheCompleteOrderedCollection() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let tracks = (0..<503).map { track("row-\($0)") } + [track("row-0", occurrence: "duplicate")]
        let source = CatalogProviderSource(playlist: .success(playlist(tracks)))
        let provider = PersistentCatalogProvider(source: source, rootDirectory: root, clock: ProviderClock())
        await provider.activate()
        _ = try await provider.profile()
        _ = try await provider.playlist(id: "one")
        await source.setPlaylist(.failure(.offline))
        #expect(try await provider.playlist(id: "one").tracks == tracks)
        #expect(await provider.retire(purge: true))
    }

    @Test func coldCleanupCannotEraseAnActiveOwnerOrReopenAdmissionAfterFailure() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let active = PersistentCatalogProvider(
            source: CatalogProviderSource(playlist: .success(playlist([track("active")]))), rootDirectory: root
        )
        await active.activate()
        _ = try await active.profile()
        _ = try await active.playlist(id: "one")

        let cold = PersistentCatalogProvider(source: CatalogProviderSource(), rootDirectory: root)
        #expect(await cold.retire(purge: true) == false)
        await cold.activate()
        await #expect(throws: CatalogReadFailure.sessionExpired) { try await cold.profile() }
        #expect(try await active.playlist(id: "one").tracks == [track("active")])
        #expect(await active.retire(purge: false))
        #expect(await cold.retire(purge: true))
        await cold.activate()
        _ = try await cold.profile()
        await #expect(throws: CatalogReadFailure.offline) { try await cold.playlist(id: "one") }
        #expect(await cold.retire(purge: true))
    }

    @Test(arguments: [nil, "", "spotify:user:", "spotify:playlist:one"])
    func unverifiedProfileNeverCreatesPersistentAccountContent(uri: String?) async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let value = playlist([track("one")])
        let source = CatalogProviderSource(
            profile: CatalogProfileSnapshot(name: "Unknown", uri: uri), playlist: .success(value)
        )
        let provider = PersistentCatalogProvider(source: source, rootDirectory: root)
        await provider.activate()
        _ = try await provider.profile()
        #expect(try await provider.playlist(id: "one") == value)
        await source.setPlaylist(.failure(.offline))
        await #expect(throws: CatalogReadFailure.offline) { try await provider.playlist(id: "one") }
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(await provider.retire(purge: true))
    }

    @Test(arguments: [CatalogReadFailure.offline, .timedOut, .throttled])
    func transientFailuresCanUseRetainedBrowsingWithoutWritePermission(failure: CatalogReadFailure) async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = CatalogProviderSource(playlist: .success(playlist([track("one")])))
        let provider = PersistentCatalogProvider(source: source, rootDirectory: root, clock: ProviderClock())
        await provider.activate()
        _ = try await provider.profile()
        _ = try await provider.playlist(id: "one")
        await source.setPlaylist(.failure(failure))
        let cached = try await provider.playlist(id: "one")
        #expect(cached.tracks == [track("one")])
        #expect(!cached.freshness.isCurrent)
        #expect(cached.ownerURI == nil)
        #expect(cached.item?.ownerURI == nil)
        #expect(await provider.retire(purge: true))
    }

    @Test(arguments: [CatalogReadFailure.sessionExpired, .compatibility, .unavailable])
    func credentialAndCompatibilityFailuresDoNotDisappearBehindCachedContent(failure: CatalogReadFailure) async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = CatalogProviderSource(playlist: .success(playlist([track("one")])))
        let provider = PersistentCatalogProvider(source: source, rootDirectory: root)
        await provider.activate()
        _ = try await provider.profile()
        _ = try await provider.playlist(id: "one")
        await source.setPlaylist(.failure(failure))
        await #expect(throws: failure) { try await provider.playlist(id: "one") }
        #expect(await provider.retire(purge: true))
    }

    @Test func suspendedReadCannotPublishOrPersistAfterRetirement() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = CatalogProviderSource(playlist: .success(playlist([track("before-retirement")])))
        let provider = PersistentCatalogProvider(source: source, rootDirectory: root)
        await provider.activate()
        _ = try await provider.profile()
        _ = try await provider.playlist(id: "one")
        let gate = CatalogReadGate<CatalogPlaylistSnapshot>()
        await source.holdPlaylist(gate)
        let pending = Task { try await provider.playlist(id: "one") }
        await gate.waitUntilEntered()
        #expect(await provider.retire(purge: true))
        await gate.release(playlist([track("late-result")]))
        await #expect(throws: CatalogReadFailure.sessionExpired) { try await pending.value }

        let replacement = PersistentCatalogProvider(source: CatalogProviderSource(), rootDirectory: root)
        await replacement.activate()
        _ = try await replacement.profile()
        await #expect(throws: CatalogReadFailure.offline) { try await replacement.playlist(id: "one") }
        #expect(await replacement.retire(purge: true))
    }

    @Test func suspendedAccountProofCannotBindARetiredLifetime() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = CatalogProviderSource()
        let gate = CatalogReadGate<CatalogProfileSnapshot>()
        await source.holdProfile(gate)
        let provider = PersistentCatalogProvider(source: source, rootDirectory: root)
        await provider.activate()
        let pending = Task { try await provider.profile() }
        await gate.waitUntilEntered()
        #expect(await provider.retire(purge: true))
        await gate.release(CatalogProfileSnapshot(name: "Late", uri: "spotify:user:account-a"))
        await #expect(throws: CatalogReadFailure.sessionExpired) { try await pending.value }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test(arguments: [nil, "spotify:user:account-b"])
    func accountMismatchRequiresRetirementBeforeActivationCanResume(replacementURI: String?) async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = CatalogProviderSource(playlist: .success(playlist([track("account-a-only")])))
        let provider = PersistentCatalogProvider(source: source, rootDirectory: root)
        await provider.activate()
        _ = try await provider.profile()
        _ = try await provider.playlist(id: "one")
        await source.setProfile(CatalogProfileSnapshot(name: "B", uri: replacementURI))
        await #expect(throws: CatalogReadFailure.sessionExpired) { try await provider.profile() }
        await provider.activate()
        await #expect(throws: CatalogReadFailure.sessionExpired) { try await provider.playlist(id: "one") }
        #expect(await provider.retire(purge: true))
        await provider.activate()
        _ = try await provider.profile()
        await source.setPlaylist(.failure(.offline))
        await #expect(throws: CatalogReadFailure.offline) { try await provider.playlist(id: "one") }
        #expect(await provider.retire(purge: true))
    }

    @Test func failedCleanupKeepsAdmissionClosedUntilPurgeCanBeRetried() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = CatalogProviderSource(playlist: .success(playlist([track("one")])))
        let provider = PersistentCatalogProvider(source: source, rootDirectory: root)
        await provider.activate()
        _ = try await provider.profile()
        _ = try await provider.playlist(id: "one")
        let directories = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        )
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let directory = try #require(directories.first)
        // A non-regular sidecar is a deterministic cleanup failure; no system permissions change.
        let obstruction = directory.appendingPathComponent("catalog.sqlite-journal")
        try FileManager.default.createDirectory(at: obstruction, withIntermediateDirectories: false)
        #expect(await provider.retire(purge: true) == false)
        await provider.activate()
        await #expect(throws: CatalogReadFailure.sessionExpired) { try await provider.profile() }
        #expect(await provider.retire(purge: false) == false)
        try FileManager.default.removeItem(at: obstruction)
        #expect(await provider.retire(purge: true))
        await provider.activate()
        _ = try await provider.profile()
        await source.setPlaylist(.failure(.offline))
        await #expect(throws: CatalogReadFailure.offline) { try await provider.playlist(id: "one") }
        #expect(await provider.retire(purge: true))
    }

    private func playlist(_ tracks: [CatalogTrack]) -> CatalogPlaylistSnapshot {
        CatalogPlaylistSnapshot(
            description: "Retained description", ownerURI: "spotify:user:account-a", tracks: tracks,
            item: CatalogItem(
                id: "one", uri: "spotify:playlist:one", title: "Retained playlist", subtitle: "Account A",
                artworkURL: nil, kind: .playlist, ownerURI: "spotify:user:account-a"
            )
        )
    }

    private func track(_ id: String, occurrence: String? = nil) -> CatalogTrack {
        CatalogTrack(
            id: occurrence ?? id, uri: "spotify:track:\(id)", title: id, artist: "Fixture artist",
            album: "Fixture album",
            duration: 180, artworkURL: nil, addedAt: nil
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("spotty-provider-check-\(UUID().uuidString)")
    }
}

// The desktop HarnessCatalog lives in SpottyBoundaryTests and cannot be imported by the headless
// runtime suite. This fake exposes only contract reads and deterministic suspended responses.
private actor CatalogProviderSource: CatalogProviding {
    private(set) var profileCalls = 0
    private(set) var playlistCalls = 0
    private var profileValue: CatalogProfileSnapshot
    private var playlistResult: Result<CatalogPlaylistSnapshot, CatalogReadFailure>
    private var albumResult: Result<CatalogAlbumSnapshot, CatalogReadFailure>
    private var playlistGate: CatalogReadGate<CatalogPlaylistSnapshot>?
    private var profileGate: CatalogReadGate<CatalogProfileSnapshot>?

    init(
        profile: CatalogProfileSnapshot = CatalogProfileSnapshot(name: "Account A", uri: "spotify:user:account-a"),
        playlist: Result<CatalogPlaylistSnapshot, CatalogReadFailure> = .failure(.offline),
        album: Result<CatalogAlbumSnapshot, CatalogReadFailure> = .failure(.offline)
    ) {
        profileValue = profile
        playlistResult = playlist
        albumResult = album
    }

    func setPlaylist(_ value: Result<CatalogPlaylistSnapshot, CatalogReadFailure>) { playlistResult = value }
    func setProfile(_ value: CatalogProfileSnapshot) { profileValue = value }
    func holdPlaylist(_ gate: CatalogReadGate<CatalogPlaylistSnapshot>) { playlistGate = gate }
    func holdProfile(_ gate: CatalogReadGate<CatalogProfileSnapshot>) { profileGate = gate }

    func profile() async -> CatalogProfileSnapshot {
        profileCalls += 1
        if let profileGate { return await profileGate.read() }
        return profileValue
    }
    func playlist(id _: String) async throws -> CatalogPlaylistSnapshot {
        playlistCalls += 1
        if let playlistGate { return await playlistGate.read() }
        return try playlistResult.get()
    }
    func album(id _: String) throws -> CatalogAlbumSnapshot { try albumResult.get() }
    func searchTracks(_: String, limit _: Int) -> [CatalogTrack] { [] }
    func home() -> CatalogHomeSnapshot { CatalogHomeSnapshot(greeting: "Hello", sections: []) }
    func playlistLibrary() -> [PlaylistLibraryNode] { [] }
    func libraryAlbums() -> [CatalogItem] { [] }
    func libraryArtists() -> [CatalogItem] { [] }
    func libraryTracks() -> [CatalogTrack] { [] }
}

private struct ProviderClock: PlaybackClock {
    static let instant = Date(timeIntervalSince1970: 1_780_000_000)
    func now() -> Date { Self.instant }
    func sleep(seconds _: TimeInterval) async throws { throw CatalogProviderCapabilityError.unsupported }
}

private actor CatalogReadGate<Value: Sendable> {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var resultWaiter: CheckedContinuation<Value, Never>?

    func read() async -> Value {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        return await withCheckedContinuation { resultWaiter = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release(_ value: Value) {
        resultWaiter?.resume(returning: value)
        resultWaiter = nil
    }
}
