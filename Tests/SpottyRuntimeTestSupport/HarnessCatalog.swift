import SpottyTestSupport
import Foundation
import SpottyDomain
import SpottyRuntimeContracts

/// Scripts the catalog port directly; wire validation and mapping belong to Gateway tests.
final class HarnessCatalog: CatalogProviding, CatalogEntityQueryProviding, @unchecked Sendable {
    struct SearchCall: Equatable, Sendable {
        let term: String
        let limit: Int
    }

    private struct Storage {
        var searchTrackCalls: [SearchCall] = []
        var entityQueries: (any CatalogEntityQueryProviding)?
        var onSearchTracks: (@Sendable (String, Int) async throws -> [CatalogTrack])?
        var onSearchAlbums: (@Sendable (String, Int) async throws -> [CatalogItem])?
        var onSearchArtists: (@Sendable (String, Int) async throws -> [CatalogItem])?
        var onSearchPlaylists: (@Sendable (String, Int) async throws -> [CatalogItem])?
        var onHome: (@Sendable () async throws -> CatalogHomeSnapshot)?
        var onPlaylistLibrary: (@Sendable () async throws -> [PlaylistLibraryNode])?
        var onCachedPlaylistLibrary: (@Sendable () async throws -> CatalogPlaylistLibrarySnapshot?)?
        var onLibraryAlbums: (@Sendable () async throws -> [CatalogItem])?
        var onLibraryArtists: (@Sendable () async throws -> [CatalogItem])?
        var onLibraryTracks: (@Sendable () async throws -> [CatalogTrack])?
        var onProfile: (@Sendable () async throws -> CatalogProfileSnapshot)?
        var onCachedPlaylist: (@Sendable (String) async throws -> CatalogPlaylistSnapshot?)?
        var onPlaylist: (@Sendable (String) async throws -> CatalogPlaylistSnapshot)?
        var onCachedAlbum: (@Sendable (String) async throws -> CatalogAlbumSnapshot?)?
        var onAlbum: (@Sendable (String) async throws -> CatalogAlbumSnapshot)?
        var onArtist: (@Sendable (String) async throws -> CatalogArtistSnapshot)?
        var onArtistDiscography: (@Sendable (String) async throws -> CatalogArtistSnapshot)?
    }

    private let lock = NSLock()
    private var storage = Storage()
    private let counters = HarnessCounters()

    init() {}

    private func withStorage<T>(_ body: (inout Storage) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }

    // MARK: Configuration

    /// Inert by default, preserving callers that do not opt into retained entity queries.
    var entityQueries: (any CatalogEntityQueryProviding)? {
        get { withStorage { $0.entityQueries } }
        set { withStorage { $0.entityQueries = newValue } }
    }

    var onSearchTracks: (@Sendable (String, Int) async throws -> [CatalogTrack])? {
        get { withStorage { $0.onSearchTracks } }
        set { withStorage { $0.onSearchTracks = newValue } }
    }

    var onSearchAlbums: (@Sendable (String, Int) async throws -> [CatalogItem])? {
        get { withStorage { $0.onSearchAlbums } }
        set { withStorage { $0.onSearchAlbums = newValue } }
    }

    var onSearchArtists: (@Sendable (String, Int) async throws -> [CatalogItem])? {
        get { withStorage { $0.onSearchArtists } }
        set { withStorage { $0.onSearchArtists = newValue } }
    }

    var onSearchPlaylists: (@Sendable (String, Int) async throws -> [CatalogItem])? {
        get { withStorage { $0.onSearchPlaylists } }
        set { withStorage { $0.onSearchPlaylists = newValue } }
    }

    var onHome: (@Sendable () async throws -> CatalogHomeSnapshot)? {
        get { withStorage { $0.onHome } }
        set { withStorage { $0.onHome = newValue } }
    }

    var onPlaylistLibrary: (@Sendable () async throws -> [PlaylistLibraryNode])? {
        get { withStorage { $0.onPlaylistLibrary } }
        set { withStorage { $0.onPlaylistLibrary = newValue } }
    }

    var onCachedPlaylistLibrary: (@Sendable () async throws -> CatalogPlaylistLibrarySnapshot?)? {
        get { withStorage { $0.onCachedPlaylistLibrary } }
        set { withStorage { $0.onCachedPlaylistLibrary = newValue } }
    }

    var onLibraryAlbums: (@Sendable () async throws -> [CatalogItem])? {
        get { withStorage { $0.onLibraryAlbums } }
        set { withStorage { $0.onLibraryAlbums = newValue } }
    }

    var onLibraryArtists: (@Sendable () async throws -> [CatalogItem])? {
        get { withStorage { $0.onLibraryArtists } }
        set { withStorage { $0.onLibraryArtists = newValue } }
    }

    var onLibraryTracks: (@Sendable () async throws -> [CatalogTrack])? {
        get { withStorage { $0.onLibraryTracks } }
        set { withStorage { $0.onLibraryTracks = newValue } }
    }

    var onProfile: (@Sendable () async throws -> CatalogProfileSnapshot)? {
        get { withStorage { $0.onProfile } }
        set { withStorage { $0.onProfile = newValue } }
    }

    var onCachedPlaylist: (@Sendable (String) async throws -> CatalogPlaylistSnapshot?)? {
        get { withStorage { $0.onCachedPlaylist } }
        set { withStorage { $0.onCachedPlaylist = newValue } }
    }

    var onPlaylist: (@Sendable (String) async throws -> CatalogPlaylistSnapshot)? {
        get { withStorage { $0.onPlaylist } }
        set { withStorage { $0.onPlaylist = newValue } }
    }

    var onCachedAlbum: (@Sendable (String) async throws -> CatalogAlbumSnapshot?)? {
        get { withStorage { $0.onCachedAlbum } }
        set { withStorage { $0.onCachedAlbum = newValue } }
    }

    var onAlbum: (@Sendable (String) async throws -> CatalogAlbumSnapshot)? {
        get { withStorage { $0.onAlbum } }
        set { withStorage { $0.onAlbum = newValue } }
    }

    var onArtist: (@Sendable (String) async throws -> CatalogArtistSnapshot)? {
        get { withStorage { $0.onArtist } }
        set { withStorage { $0.onArtist = newValue } }
    }

    var onArtistDiscography: (@Sendable (String) async throws -> CatalogArtistSnapshot)? {
        get { withStorage { $0.onArtistDiscography } }
        set { withStorage { $0.onArtistDiscography = newValue } }
    }

    // MARK: Observation

    func count(_ name: String) -> Int { counters.count(name) }

    var searchTrackCalls: [SearchCall] { withStorage { $0.searchTrackCalls } }

    var searchTrackRequestCount: Int { counters.count("searchTracks") }
    var homeRequestCount: Int { counters.count("home") }
    var playlistLibraryRequestCount: Int { counters.count("playlistLibrary") }
    var libraryAlbumRequestCount: Int { counters.count("libraryAlbums") }
    var libraryArtistRequestCount: Int { counters.count("libraryArtists") }
    var libraryTrackRequestCount: Int { counters.count("libraryTracks") }
    var profileRequestCount: Int { counters.count("profile") }
    var playlistRequestCount: Int { counters.count("playlist") }
    var albumRequestCount: Int { counters.count("album") }
    var artistRequestCount: Int { counters.count("artist") }
    var discographyRequestCount: Int { counters.count("artistDiscography") }

    // MARK: CatalogProviding

    func searchTracks(_ term: String, limit: Int) async throws -> [CatalogTrack] {
        withStorage { $0.searchTrackCalls.append(SearchCall(term: term, limit: limit)) }
        counters.record("searchTracks")
        guard let override = onSearchTracks else { throw HarnessFailure.unavailable }
        return try await override(term, limit)
    }

    func searchAlbums(_ term: String, limit: Int) async throws -> [CatalogItem] {
        counters.record("searchAlbums")
        guard let override = onSearchAlbums else { throw CatalogProviderCapabilityError.unsupported }
        return try await override(term, limit)
    }

    func searchArtists(_ term: String, limit: Int) async throws -> [CatalogItem] {
        counters.record("searchArtists")
        guard let override = onSearchArtists else { throw CatalogProviderCapabilityError.unsupported }
        return try await override(term, limit)
    }

    func searchPlaylists(_ term: String, limit: Int) async throws -> [CatalogItem] {
        counters.record("searchPlaylists")
        guard let override = onSearchPlaylists else { throw CatalogProviderCapabilityError.unsupported }
        return try await override(term, limit)
    }

    func home() async throws -> CatalogHomeSnapshot {
        counters.record("home")
        guard let override = onHome else { throw HarnessFailure.unavailable }
        return try await override()
    }

    func playlistLibrary() async throws -> [PlaylistLibraryNode] {
        counters.record("playlistLibrary")
        guard let override = onPlaylistLibrary else { throw HarnessFailure.unavailable }
        return try await override()
    }

    func cachedPlaylistLibrary() async throws -> CatalogPlaylistLibrarySnapshot? {
        counters.record("cachedPlaylistLibrary")
        return try await onCachedPlaylistLibrary?()
    }

    func libraryAlbums() async throws -> [CatalogItem] {
        counters.record("libraryAlbums")
        guard let override = onLibraryAlbums else { throw HarnessFailure.unavailable }
        return try await override()
    }

    func libraryArtists() async throws -> [CatalogItem] {
        counters.record("libraryArtists")
        guard let override = onLibraryArtists else { throw HarnessFailure.unavailable }
        return try await override()
    }

    func libraryTracks() async throws -> [CatalogTrack] {
        counters.record("libraryTracks")
        guard let override = onLibraryTracks else { throw HarnessFailure.unavailable }
        return try await override()
    }

    func profile() async throws -> CatalogProfileSnapshot {
        counters.record("profile")
        guard let override = onProfile else { throw HarnessFailure.unavailable }
        return try await override()
    }

    func cachedPlaylist(id: String) async throws -> CatalogPlaylistSnapshot? {
        counters.record("cachedPlaylist")
        return try await onCachedPlaylist?(id)
    }

    func playlist(id: String) async throws -> CatalogPlaylistSnapshot {
        counters.record("playlist")
        guard let override = onPlaylist else { throw HarnessFailure.unavailable }
        return try await override(id)
    }

    func cachedAlbum(id: String) async throws -> CatalogAlbumSnapshot? {
        counters.record("cachedAlbum")
        return try await onCachedAlbum?(id)
    }

    func album(id: String) async throws -> CatalogAlbumSnapshot {
        counters.record("album")
        guard let override = onAlbum else { throw CatalogProviderCapabilityError.unsupported }
        return try await override(id)
    }

    func artist(id: String) async throws -> CatalogArtistSnapshot {
        counters.record("artist")
        guard let override = onArtist else { throw CatalogProviderCapabilityError.unsupported }
        return try await override(id)
    }

    func artistDiscography(id: String) async throws -> CatalogArtistSnapshot {
        counters.record("artistDiscography")
        guard let override = onArtistDiscography else { throw CatalogProviderCapabilityError.unsupported }
        return try await override(id)
    }
    func subscribeCatalogEntities(_ uris: Set<String>) async throws -> CatalogEntitySubscription {
        guard let entityQueries else { throw CatalogEntityQueryFailure.unavailable }
        return try await entityQueries.subscribeCatalogEntities(uris)
    }

    func catalogEntities(for change: CatalogEntityChange) async throws -> [String: CatalogTrackMetadata] {
        guard let entityQueries else { throw CatalogEntityQueryFailure.unavailable }
        return try await entityQueries.catalogEntities(for: change)
    }

    func acknowledgeCatalogEntities(_ token: CatalogEntitySubscriptionToken, revision: UInt64) async {
        await entityQueries?.acknowledgeCatalogEntities(token, revision: revision)
    }

    func unsubscribeCatalogEntities(_ token: CatalogEntitySubscriptionToken) async {
        await entityQueries?.unsubscribeCatalogEntities(token)
    }

}
