import Foundation
import SpottyDomain
import SpottyRuntimeContracts
@testable import SpottyCore
import SpottyEngineAdapter
@testable import SpottySessionRuntime
@testable import SpottyGateway

/// One lock owns every mutable port value, including the synchronous engine boundary.
/// Playback scenarios delegate to one synthetic authority; browsing remains read-only.
final class BrowsingWorld: AccountSession, CatalogProviding, PlaylistMutationDispatching,
    RemotePlaybackClient, LocalPlaybackEngine, WebQueueClient, AudioOutputPreparing,
    PlaybackPreferences, SystemLifecycleEvents, PlaybackClock, @unchecked Sendable
{
    let scenario: BrowsingScenario
    let playback = SyntheticPlayback()
    let fixtures: BrowsingFixtures
    private let lock = NSLock()
    private var trace: [String] = []
    private var requestCounts: [String: Int] = [:]
    private var mutationAttempts = 0
    private var grantAvailable: Bool
    private var shuffle = false
    private var lastDevice: String?
    private var history: [String: TimeInterval] = [:]
    private var sleepers: [UUID: CheckedContinuation<Void, Error>] = [:]

    struct Snapshot: Codable, Equatable, Sendable {
        let requests: [String: Int]
        let mutationAttempts: Int
        let trace: [String]
    }

    init(scenario: BrowsingScenario, artworkDirectory: URL) throws {
        self.scenario = scenario
        grantAvailable = scenario.mode != .signedOut
        fixtures = try BrowsingFixtures(scenario: scenario, artworkDirectory: artworkDirectory)
    }

    var environment: PlaybackEnvironment {
        PlaybackEnvironment(
            remote: self, local: self, webQueue: self, account: self, audioOutput: self,
            preferences: self, lifecycle: self, clock: self, catalog: self,
            playlistMutations: self, artwork: ArtworkPipeline(allowFileURLs: true)
        )
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                requests: requestCounts, mutationAttempts: mutationAttempts,
                trace: trace)
        }
    }

    private func record(_ name: String) {
        lock.withLock {
            requestCounts[name, default: 0] += 1
            if trace.count < 256 { trace.append(name) }
        }
    }

    private func rejectMutation() -> BrowsingFailure {
        lock.withLock { mutationAttempts += 1 }
        return .unsupportedAction
    }

    func hasGrant() async -> Bool { record("account.has-grant"); return lock.withLock { grantAvailable } }
    func authorizeInteractively() async throws -> KeymasterTokens { throw rejectMutation() }
    func accessToken() async throws -> String { throw BrowsingFailure.unsupportedAction }
    func adopt(_: KeymasterTokens) async throws { throw rejectMutation() }
    func clear() async -> Bool {
        guard scenario.mode == .playback else { _ = rejectMutation(); return true }
        lock.withLock { grantAvailable = false }
        record("account.synthetic-clear")
        return true
    }

    func restoreSyntheticAccount() {
        guard scenario.mode == .playback else { return }
        lock.withLock { grantAvailable = true }
        playback.replaceSession(publish: false)
        record("account.synthetic-replacement")
    }
    func revocations() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    func prepareForPlayback() throws { record("audio.no-device") }
    func events() -> AsyncStream<RustPlaybackEventEnvelope> { playback.events() }
    func events() -> AsyncStream<SystemLifecycleEvent> { AsyncStream { $0.finish() } }
    func initialize() -> PlaybackEngineResult {
        record("engine.synthetic-initialize")
        if scenario.mode == .playback { playback.publish() }
        return .ok
    }
    func authorizeStreaming(with _: String) -> Int32 { _ = rejectMutation(); return -1 }
    func execute(_ operation: LocalPlaybackOperation) -> PlaybackEngineResult {
        guard scenario.mode == .playback else { _ = rejectMutation(); return .error }
        record("playback.local-command")
        return playback.execute(operation)
    }
    func positionMilliseconds() -> UInt32 { UInt32(clamping: playback.snapshot().positionMS) }
    func queueSnapshot() -> RustQueueState? { scenario.mode == .playback ? playback.queueSnapshot() : nil }
    func shutdown() -> PlaybackEngineResult { record("engine.synthetic-shutdown"); return .ok }
    func cleanup() {}
    func clearStreamingCredentials() {
        if scenario.mode == .playback { record("engine.synthetic-clear") } else { _ = rejectMutation() }
    }
    func disconnect() -> PlaybackEngineResult { _ = rejectMutation(); return .error }
    func forceReconnect() -> Int32 {
        guard scenario.mode == .playback else { _ = rejectMutation(); return -1 }
        record("playback.reconnect")
        playback.replaceSession(preservingPlayback: true)
        return 0
    }
    func send(_ command: SpotifyConnectCommand, from source: String, to target: String) async throws {
        guard scenario.mode == .playback, source == SyntheticPlayback.localID else { throw rejectMutation() }
        record("playback.remote-command")
        try playback.send(command, to: target)
    }
    func trackMetadata(for uri: String) async throws -> SpotifyConnectTrackMetadata {
        guard scenario.mode == .playback, uri.hasPrefix("spotify:track:synthetic") else {
            throw BrowsingFailure.unsupportedAction
        }
        record("playback.metadata")
        if uri.hasPrefix("spotify:track:syntheticWave") {
            try await ContinuousClock().sleep(for: .milliseconds(15))
        }
        let suffix = uri.split(separator: "x").last.flatMap { Int($0) } ?? 0
        return SpotifyConnectTrackMetadata(
            uri: uri, title: BrowsingFixtures.trackName(at: suffix),
            artist: BrowsingFixtures.artistName(at: suffix),
            artworkURL: fixtures.artworkURLs[suffix % fixtures.artworkURLs.count],
            duration: 180, artists: suffix == 0 ? [fixtures.artists[0]] : [],
            albumItem: suffix == 0 ? fixtures.albums[0] : nil)
    }
    func queue() async throws -> [CatalogTrack] { [] }
    func shuffleEnabled() async -> Bool { lock.withLock { shuffle } }
    func setShuffleEnabled(_ value: Bool) async { lock.withLock { shuffle = value } }
    func lastRemoteDeviceID() async -> String? { lock.withLock { lastDevice } }
    func setLastRemoteDeviceID(_ value: String?) async { lock.withLock { lastDevice = value } }
    func shuffleHistory() async -> [String: TimeInterval] { lock.withLock { history } }
    func setShuffleHistory(_ value: [String: TimeInterval]) async { lock.withLock { history = value } }
    func now() -> Date { scenario.mode == .playback ? Date() : Date(timeIntervalSince1970: 1_800_000_000) }

    /// Browsing has no playback time events. Park background timers until their owner cancels.
    func sleep(seconds: TimeInterval) async throws {
        if scenario.mode == .playback {
            try await ContinuousClock().sleep(for: .seconds(seconds))
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let cancelled = lock.withLock {
                    if Task.isCancelled { return true }
                    sleepers[id] = continuation
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let continuation = self.lock.withLock { self.sleepers.removeValue(forKey: id) }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func home() async throws -> CatalogHomeSnapshot {
        record("home")
        let home = CatalogMapping.home(fixtures.home)
        guard scenario.expandedLibrary == true else { return home }
        return CatalogHomeSnapshot(
            greeting: home.greeting,
            sections: home.sections + [
                CatalogSection(
                    id: "synthetic-recommendations", title: "Playlists for you",
                    items: fixtures.playlists.prefix(10).compactMap(CatalogMapping.playlistRecommendation(from:))),
                CatalogSection(id: "synthetic-albums", title: "Albums for you", items: fixtures.albums),
                CatalogSection(id: "synthetic-artists", title: "Artists for you", items: fixtures.artists),
            ])
    }
    func playlistLibrary() async throws -> [PlaylistLibraryNode] {
        record("library")
        if let delay = scenario.playlistRefreshMilliseconds {
            try await ContinuousClock().sleep(for: .milliseconds(delay))
        }
        return playlistNodes()
    }

    func cachedPlaylistLibrary() async throws -> CatalogPlaylistLibrarySnapshot? {
        guard scenario.cachedPlaylistLibrary == true else { return nil }
        return CatalogPlaylistLibrarySnapshot(nodes: playlistNodes().map(\.withoutOwnership), fetchedAt: now())
    }

    private func playlistNodes() -> [PlaylistLibraryNode] {
        let nodes = fixtures.playlists.compactMap(CatalogMapping.item(from:))
            .map(PlaylistLibraryNode.init(playlist:))
        guard scenario.expandedLibrary == true else { return nodes }
        let folders = BrowsingFixtures.folderNames.enumerated().map { index, name in
            let offset = BrowsingFixtures.topLevelPlaylistCount + index * BrowsingFixtures.playlistsPerFolder
            return PlaylistLibraryNode(
                folderURI: "spotify:folder:synthetic-\(name.lowercased())", title: name,
                children: Array(nodes.dropFirst(offset).prefix(BrowsingFixtures.playlistsPerFolder)))
        }
        return folders + Array(nodes.prefix(BrowsingFixtures.topLevelPlaylistCount))
    }

    func profile() async throws -> CatalogProfileSnapshot {
        CatalogProfileSnapshot(name: BrowsingFixtures.listenerName(at: 0), uri: "spotify:user:synthetic")
    }
    private func delayDetailRefresh() async throws {
        if let delay = scenario.detailRefreshMilliseconds {
            try await ContinuousClock().sleep(for: .milliseconds(delay))
        }
    }

    func cachedPlaylist(id: String) async throws -> CatalogPlaylistSnapshot? {
        guard scenario.cachedDetails == true, let result = fixtures.details[id] else { return nil }
        let snapshot = CatalogMapping.playlist(result)
        return CatalogPlaylistSnapshot(
            description: snapshot.description, ownerURI: nil, tracks: snapshot.tracks,
            item: snapshot.item.map {
                CatalogItem(
                    id: $0.id, uri: $0.uri, title: $0.title, subtitle: $0.subtitle, artworkURL: $0.artworkURL,
                    kind: $0.kind)
            },
            freshness: .cached(fetchedAt: now()))
    }

    func cachedAlbum(id: String) async throws -> CatalogAlbumSnapshot? {
        guard scenario.cachedDetails == true, let album = fixtures.album(id: id) ?? fixtures.artistAlbum(id: id) else {
            return nil
        }
        return CatalogAlbumSnapshot(
            tracks: album.tracks, releaseDate: album.releaseDate, item: album.item,
            freshness: .cached(fetchedAt: now()), playCounts: album.playCounts, artists: album.artists)
    }

    func playlist(id: String) async throws -> CatalogPlaylistSnapshot {
        record("playlist.\(id)")
        try await delayDetailRefresh()
        guard let result = fixtures.details[id] else { throw BrowsingFailure.unsupportedAction }
        return CatalogMapping.playlist(result)
    }
    func album(id: String) async throws -> CatalogAlbumSnapshot {
        record("album.\(id)")
        try await delayDetailRefresh()
        guard let album = fixtures.album(id: id) ?? fixtures.artistAlbum(id: id) else {
            throw BrowsingFailure.unsupportedAction
        }
        return album
    }
    func artist(id: String) async throws -> CatalogArtistSnapshot {
        record("artist.\(id)")
        guard let artist = fixtures.artist(id: id) else { throw BrowsingFailure.unsupportedAction }
        return artist
    }
    func artistDiscography(id: String) async throws -> CatalogArtistSnapshot {
        try await artist(id: id)
    }
    func libraryAlbums() async throws -> [CatalogItem] {
        scenario.expandedLibrary == true ? fixtures.albums : []
    }
    func libraryArtists() async throws -> [CatalogItem] { [] }
    func libraryTracks() async throws -> [CatalogTrack] { [] }
    func searchTracks(_ query: String, limit: Int) async throws -> [CatalogTrack] {
        record("search.tracks")
        let tracks = fixtures.albums.flatMap {
            fixtures.album(id: String($0.uri.split(separator: ":").last ?? ""))?.tracks ?? []
        }
        return Array(
            tracks.filter {
                matchesSearch(query, text: "\($0.title) \($0.artist) \($0.album)")
            }.prefix(max(0, limit)))
    }

    func searchArtists(_ query: String, limit: Int) async throws -> [CatalogItem] {
        record("search.artists")
        return searchItems(fixtures.artists, query: query, limit: limit)
    }

    func searchAlbums(_ query: String, limit: Int) async throws -> [CatalogItem] {
        record("search.albums")
        return searchItems(fixtures.albums, query: query, limit: limit)
    }

    func searchPlaylists(_ query: String, limit: Int) async throws -> [CatalogItem] {
        record("search.playlists")
        return searchItems(fixtures.playlists.compactMap(CatalogMapping.item(from:)), query: query, limit: limit)
    }

    private func searchItems(_ items: [CatalogItem], query: String, limit: Int) -> [CatalogItem] {
        Array(items.filter { matchesSearch(query, text: "\($0.title) \($0.subtitle)") }.prefix(max(0, limit)))
    }

    private func matchesSearch(_ query: String, text: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        return !words.isEmpty && words.allSatisfy { text.localizedStandardContains(String($0)) }
    }
    func addToPlaylist(
        playlistId _: String, trackUris _: [String], authorization: PlaylistMutationAuthorization
    ) async throws {
        try authorization.authorizeDispatch()
        throw rejectMutation()
    }
    func removeFromPlaylist(
        playlistId _: String, uids _: [String], authorization: PlaylistMutationAuthorization
    ) async throws {
        try authorization.authorizeDispatch()
        throw rejectMutation()
    }
}
