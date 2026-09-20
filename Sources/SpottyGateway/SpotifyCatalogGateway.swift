import Foundation
import SpottyDomain
import SpottyRuntimeContracts

/// Converts private service responses before they cross the compiler boundary.
struct SpotifyCatalogGateway: CatalogProviding, PlaylistMutationDispatching {
    let api: PartnerAPI
    let mutationAPI: (@Sendable (PlaylistMutationAuthorization) async -> PartnerAPI)?

    init(
        api: PartnerAPI,
        mutationAPI: (@Sendable (PlaylistMutationAuthorization) async -> PartnerAPI)? = nil
    ) {
        self.api = api
        self.mutationAPI = mutationAPI
    }

    func searchTracks(_ term: String, limit: Int) async throws -> [CatalogTrack] {
        try await read { try await api.searchTracks(term, limit: limit).compactMap(CatalogMapping.searchTrack(from:)) }
    }
    func searchAlbums(_ term: String, limit: Int) async throws -> [CatalogItem] {
        try await read { try await api.searchAlbums(term, limit: limit).compactMap(CatalogMapping.item(from:)) }
    }
    func searchArtists(_ term: String, limit: Int) async throws -> [CatalogItem] {
        try await read { try await api.searchArtists(term, limit: limit).compactMap(CatalogMapping.item(from:)) }
    }
    func searchPlaylists(_ term: String, limit: Int) async throws -> [CatalogItem] {
        try await read { try await api.searchPlaylists(term, limit: limit).compactMap(CatalogMapping.item(from:)) }
    }
    func home() async throws -> CatalogHomeSnapshot {
        try await read { CatalogMapping.home(try await api.home()) }
    }
    func playlistLibrary() async throws -> [PlaylistLibraryNode] {
        try await read { try await api.playlistLibrary() }
    }
    func libraryAlbums() async throws -> [CatalogItem] {
        try await read { try await api.libraryAlbums().compactMap(CatalogMapping.item(from:)) }
    }
    func libraryArtists() async throws -> [CatalogItem] {
        try await read { try await api.libraryArtists().compactMap(CatalogMapping.item(from:)) }
    }
    func libraryTracks() async throws -> [CatalogTrack] {
        try await read { try await api.libraryTracks().compactMap(CatalogMapping.track(from:)) }
    }
    func profile() async throws -> CatalogProfileSnapshot {
        try await read { CatalogMapping.profile(try await api.profile()) }
    }
    func playlist(id: String) async throws -> CatalogPlaylistSnapshot {
        try await read { CatalogMapping.playlist(try await api.playlist(id: id)) }
    }
    func album(id: String) async throws -> CatalogAlbumSnapshot {
        try await read { CatalogMapping.album(try await api.album(id: id)) }
    }
    func artist(id: String) async throws -> CatalogArtistSnapshot {
        try await read { CatalogMapping.artist(try await api.artist(id: id)) }
    }
    func artistDiscography(id: String) async throws -> CatalogArtistSnapshot {
        try await read { CatalogMapping.discography(try await api.artistDiscography(id: id)) }
    }
    func addToPlaylist(
        playlistId: String, trackUris: [String], authorization: PlaylistMutationAuthorization
    ) async throws {
        try await write {
            guard !trackUris.isEmpty, trackUris.allSatisfy({ SpotifyURI.id(from: $0, kind: "track") != nil }) else {
                throw PlaylistMutationFailure.rejected
            }
            let client = try await mutationClient(authorization: authorization)
            _ = try await editablePlaylist(id: playlistId, using: client)
            try Task.checkCancellation()
            try await client.addToPlaylist(playlistId: playlistId, trackUris: trackUris, position: .bottom)
        }
    }
    func removeFromPlaylist(
        playlistId: String, uids: [String], authorization: PlaylistMutationAuthorization
    ) async throws {
        try await write {
            guard !uids.isEmpty, Set(uids).count == uids.count, uids.allSatisfy({ !$0.isEmpty }) else {
                throw PlaylistMutationFailure.rejected
            }
            let client = try await mutationClient(authorization: authorization)
            let playlist = try await editablePlaylist(id: playlistId, using: client)
            let entries = playlist.items
            let requested = Set(uids)
            let occurrences = entries.filter { entry in
                guard let uid = entry.uid else { return false }
                return requested.contains(uid)
            }
            guard occurrences.count == uids.count,
                Set(occurrences.compactMap(\.uid)) == requested,
                occurrences.allSatisfy({ entry in
                    guard let uri = entry.track?.uri, SpotifyURI.id(from: uri, kind: "track") != nil else {
                        return false
                    }
                    return uri != entry.uid
                })
            else { throw PlaylistMutationFailure.rejected }
            try Task.checkCancellation()
            try await client.removeFromPlaylist(playlistId: playlistId, uids: uids)
        }
    }

    private func mutationClient(authorization: PlaylistMutationAuthorization) async throws -> PartnerAPI {
        try authorization.authorizeDispatch()
        let client = await mutationAPI?(authorization) ?? api
        try authorization.authorizeDispatch()
        return client.checkingDispatch(authorization)
    }

    private func editablePlaylist(id: String, using client: PartnerAPI) async throws -> CompletePlaylist {
        guard !id.isEmpty else { throw PlaylistMutationFailure.rejected }
        async let profile = client.profile()
        async let playlist = client.playlist(id: id)
        let (account, value) = try await (profile, playlist)
        guard
            PlaylistEditability.canJustifyEdit(
                playlistOwnerURI: CatalogMapping.ownerURI(from: value.header),
                profileURI: CatalogMapping.profileUserURI(from: account)
            )
        else { throw PlaylistMutationFailure.rejected }
        return value
    }

    private func write(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        do { try await operation() } catch {
            if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            if error as? PlaylistMutationFailure == .rejected { throw PlaylistMutationFailure.rejected }
            if case PartnerAPIError.mutationRejected = error { throw PlaylistMutationFailure.rejected }
            throw PlaylistMutationFailure.failed
        }
    }

    private func read<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) async throws -> Value
    {
        do { return try await operation() } catch {
            if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw Self.failure(for: error)
        }
    }

    static func failure(for error: any Error) -> CatalogReadFailure {
        if case PartnerAPIError.persistedQueryNotFound = error { return .compatibility }
        if case PartnerAPIError.emptyPayload = error { return .compatibility }
        if error is DecodingError { return .compatibility }
        if error is KeymasterSessionError || error as? KeymasterAuthError == .grantRevoked { return .sessionExpired }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost: return .offline
            case .timedOut: return .timedOut
            default: break
            }
        }
        if case PartnerAPIError.requestFailed(429) = error { return .throttled }
        if error as? SpotifyRequestAdmission.Failure == .overloaded { return .throttled }
        return .unavailable
    }
}

extension CatalogMapping {
    static func home(_ value: PathfinderHome) -> CatalogHomeSnapshot {
        CatalogHomeSnapshot(greeting: value.greeting?.transformedLabel ?? "Home", sections: sections(from: value))
    }
    static func profile(_ value: PathfinderProfile) -> CatalogProfileSnapshot {
        CatalogProfileSnapshot(
            name: value.name ?? value.username ?? "Spotify Premium", uri: profileUserURI(from: value))
    }
    static func playlist(_ collection: CompletePlaylist) -> CatalogPlaylistSnapshot {
        let value = collection.header
        return CatalogPlaylistSnapshot(
            description: PlaylistDescription.plainText(from: value.description ?? ""),
            ownerURI: ownerURI(from: value),
            tracks: playlistTracks(from: collection.items),
            item: value.uri.map { uri in
                CatalogItem(
                    id: uri, uri: uri, title: value.name ?? "Untitled playlist",
                    subtitle: value.ownerV2?.data?.name ?? "Playlist",
                    artworkURL: value.images?.items?.first?.largestURL.flatMap(URL.init(string:)), kind: .playlist,
                    ownerURI: ownerURI(from: value))
            }
        )
    }
    static func album(_ collection: CompleteAlbum) -> CatalogAlbumSnapshot {
        let value = collection.header
        let tracks = collection.items.compactMap(\.track)
        return CatalogAlbumSnapshot(
            tracks: tracks.compactMap { albumTrack(from: $0, album: value) }, releaseDate: value.date?.day ?? "",
            item: value.uri.map { uri in
                CatalogItem(
                    id: uri, uri: uri, title: value.name ?? "Untitled album",
                    subtitle: value.artists?.items?.compactMap { $0.profile?.name }.joined(separator: ", ") ?? "",
                    artworkURL: value.coverArt?.largestURL.flatMap(URL.init(string:)), kind: .album)
            },
            playCounts: tracks.reduce(into: [:]) { counts, track in
                guard let uri = track.uri, !uri.isEmpty,
                    let count = track.playcount.flatMap(Int64.init), count >= 0
                else { return }
                counts[uri] = count
            },
            artists: value.artists?.items?.compactMap { artist in
                guard let uri = artist.uri, SpotifyURI.id(from: uri, kind: "artist") != nil,
                    let name = artist.profile?.name, !name.isEmpty
                else { return nil }
                return CatalogItem(id: uri, uri: uri, title: name, subtitle: "Artist", artworkURL: nil, kind: .artist)
            })
    }
    static func discography(_ collection: CompleteDiscography) -> CatalogArtistSnapshot {
        artist(collection.header.withDiscographyItems(collection.items))
    }
    static func artist(_ value: PathfinderArtistUnion) -> CatalogArtistSnapshot {
        var seen = Set<String>()
        let popularReleases = (value.discography?.popularReleasesAlbums?.releases ?? []).filter { release in
            guard let id = release.releaseId else { return false }
            return seen.insert(id).inserted
        }
        let kinds = Dictionary(
            (value.releases + popularReleases).compactMap { release -> (String, CatalogArtistReleaseKind)? in
                guard let uri = release.uri, let type = release.type,
                    let kind = CatalogArtistReleaseKind(rawValue: type.lowercased())
                else { return nil }
                return (uri, kind)
            }, uniquingKeysWith: { first, _ in first })
        let popularTracks = (value.discography?.topTracks?.items ?? []).compactMap {
            entry -> CatalogArtistPopularTrack? in
            guard let value = entry.track, let track = searchTrack(from: value.metadata) else { return nil }
            return CatalogArtistPopularTrack(
                track: track, playCount: value.playcount.flatMap(Int64.init).flatMap { $0 >= 0 ? $0 : nil },
                isPlayable: value.playability?.playable != false)
        }
        return CatalogArtistSnapshot(
            name: value.profile?.name,
            releases: value.releases.compactMap { item(from: $0, artist: value.profile?.name ?? "") },
            item: value.uri.map { uri in
                CatalogItem(
                    id: uri, uri: uri, title: value.profile?.name ?? "Unknown artist", subtitle: "Artist",
                    artworkURL: value.visuals?.avatarImage?.largestURL.flatMap(URL.init(string:)), kind: .artist)
            },
            overview: value.profile.map { _ in
                CatalogArtistOverview(
                    headerArtworkURL: value.headerImage?.data?.largestURL.flatMap(URL.init(string:)),
                    monthlyListeners: value.stats?.monthlyListeners.flatMap { $0 >= 0 ? $0 : nil },
                    isVerified: value.onPlatformReputationTrait?.verification?.isVerified == true,
                    popularTracks: popularTracks,
                    popularReleases: popularReleases.compactMap { item(from: $0, artist: value.profile?.name ?? "") },
                    featuringPlaylists: artistPlaylists(value.relatedContent?.featuringV2),
                    biography: value.profile?.biography?.text.map(PlaylistDescription.plainText),
                    aboutArtworkURL: (value.visuals?.gallery?.items?.first?.largestURL
                        ?? value.visuals?.avatarImage?.largestURL).flatMap(URL.init(string:)),
                    followers: value.stats?.followers.flatMap { $0 >= 0 ? $0 : nil },
                    discoveredOnPlaylists: artistPlaylists(value.relatedContent?.discoveredOnV2),
                    artistPlaylists: artistPlaylists(value.profile?.playlistsV2))
            }, releaseKinds: kinds,
            releaseDates: Dictionary(
                (value.releases + popularReleases).compactMap { release in
                    guard let uri = release.uri, let date = release.date?.formatted else { return nil }
                    return (uri, date)
                }, uniquingKeysWith: { first, _ in first }))
    }

    private static func artistPlaylists(_ playlists: PathfinderItems<PathfinderPlaylist>?) -> [CatalogItem] {
        var seen = Set<String>()
        return (playlists?.entities ?? []).compactMap { playlist in
            guard let item = playlistRecommendation(from: playlist), seen.insert(item.uri).inserted else { return nil }
            return item
        }
    }
}
