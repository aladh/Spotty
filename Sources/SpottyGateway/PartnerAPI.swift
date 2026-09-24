import SpottyDiagnostics
//
//  PartnerAPI.swift
//  Spotty
//
//  The GraphQL API the desktop client uses, at api-partner.spotify.com.
//

import Foundation
import SpottyRuntimeContracts
import SpottyDomain

nonisolated enum PartnerAPIError: Error, LocalizedError, Equatable {
    case requestFailed(Int)
    case persistedQueryNotFound(String)
    case graphQLErrors(String)
    case emptyPayload
    /// A write Spotify answered with HTTP 200 and a failure `__typename`.
    case mutationRejected(String)
    /// A paged walk hit `Pagination`'s request cap or failed to advance its offset.
    case pagination(Pagination.Failure)

    var errorDescription: String? {
        switch self {
        case let .requestFailed(status):
            "Spotify rejected the request (HTTP \(status))"
        case let .persistedQueryNotFound(operation):
            "Spotify no longer recognises the stored query for \(operation)"
        case let .mutationRejected(operation):
            "Spotify rejected \(operation)"
        case let .graphQLErrors(operation):
            "Spotify returned a GraphQL error for \(operation)"
        case .emptyPayload:
            "Spotify returned no data"
        case let .pagination(failure):
            failure.errorDescription
        }
    }
}

typealias Pagination = SpottyDomain.Pagination

/// The request body. At file scope rather than nested in the encoder, because the encoder
/// takes its variables as an opaque parameter and a generic type cannot be declared inside a
/// generic function.
private nonisolated struct PathfinderPersistedQuery: Encodable {
    let version = 1
    let sha256Hash: String
}

private nonisolated struct PathfinderExtensions: Encodable {
    let persistedQuery: PathfinderPersistedQuery
}

private nonisolated struct PathfinderRequestBody<Variables: Encodable>: Encodable {
    let variables: Variables
    let operationName: String
    let extensions: PathfinderExtensions
}

/// GraphQL reports failure inside a 200 body, so every response is checked for this first.
private nonisolated struct PathfinderErrorEnvelope: Decodable {
    struct Failure: Decodable {
        struct Extensions: Decodable {
            let code: String?
        }

        let message: String?
        let extensions: Extensions?
    }

    let errors: [Failure]?
}

/// Sends persisted queries to `api-partner.spotify.com`.
///
/// Authorized by the keymaster token *and* a client token: the bearer alone is a 401 here.
nonisolated struct PartnerAPI: Sendable {
    static let endpoint = URL(string: "https://api-partner.spotify.com/pathfinder/v2/query")!

    typealias Transport = SpotifyCredentials.Transport

    private let credentials: SpotifyCredentials

    init(
        accessToken: @escaping @Sendable () async throws -> String = {
            try await KeymasterSession.shared.accessToken()
        },
        clientToken: @escaping @Sendable () async throws -> String = {
            try await ClientTokenProvider.shared.token()
        },
        invalidateAccessToken: @escaping @Sendable (String) async throws -> Void = SpotifyCredentials
            .invalidateSharedAccess,
        invalidateClientToken: @escaping @Sendable (String) async -> Void = SpotifyCredentials.invalidateShared,
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) },
        retryTiming: SpotifyTransientRetry.Timing = .production,
    ) {
        credentials = SpotifyCredentials(
            accessToken: accessToken,
            clientToken: clientToken,
            invalidateAccessToken: invalidateAccessToken,
            invalidateClientToken: invalidateClientToken,
            transport: transport,
            retryTiming: retryTiming,
        )
    }

    /// Injected transports use the same per-attempt fence. Production additionally checks inside
    /// its admission wrapper, after waiting for request capacity and checking the grant identity.
    func checkingDispatch(_ authorization: PlaylistMutationAuthorization) -> PartnerAPI {
        return PartnerAPI(
            accessToken: credentials.accessToken,
            clientToken: credentials.clientToken,
            invalidateAccessToken: credentials.invalidateAccessToken,
            invalidateClientToken: credentials.invalidateClientToken,
            transport: { [credentials] request in
                try authorization.authorizeDispatch()
                return try await credentials.transport(request)
            },
            retryTiming: credentials.retryTiming
        )
    }

    // MARK: - Searches

    func searchTracks(_ term: String, limit: Int = 30) async throws -> [PathfinderTrack] {
        let response: PathfinderResponse<PathfinderTrackResults> = try await query(
            .searchTracks,
            variables: PathfinderSearchVariables(searchTerm: term, limit: limit),
        )
        guard let page = response.results?.tracksV2 else { throw PartnerAPIError.emptyPayload }
        return try page.validatedEntities()
    }

    func searchAlbums(_ term: String, limit: Int = 30) async throws -> [PathfinderAlbum] {
        let response: PathfinderResponse<PathfinderAlbumResults> = try await query(
            .searchAlbums,
            variables: PathfinderSearchVariables(searchTerm: term, limit: limit),
        )
        guard let page = response.results?.albumsV2 else { throw PartnerAPIError.emptyPayload }
        return try page.validatedEntities()
    }

    func searchArtists(_ term: String, limit: Int = 30) async throws -> [PathfinderArtist] {
        let response: PathfinderResponse<PathfinderArtistResults> = try await query(
            .searchArtists,
            variables: PathfinderSearchVariables(searchTerm: term, limit: limit),
        )
        guard let page = response.results?.artists else { throw PartnerAPIError.emptyPayload }
        return try page.validatedEntities()
    }

    func searchPlaylists(_ term: String, limit: Int = 30) async throws -> [PathfinderPlaylist] {
        let response: PathfinderResponse<PathfinderPlaylistResults> = try await query(
            .searchPlaylists,
            variables: PathfinderSearchVariables(searchTerm: term, limit: limit),
        )
        guard let page = response.results?.playlists else { throw PartnerAPIError.emptyPayload }
        return try page.validatedEntities()
    }

    // MARK: - Album

    /// Complete ordered album contents; paging finishes before the snapshot can be published.
    func album(id: String) async throws -> CompleteAlbum {
        let uri = "spotify:album:\(id)"
        return try await CompleteAlbum.collect { offset in
            let response: PathfinderAlbumResponse = try await query(
                .getAlbum, variables: PathfinderAlbumVariables(uri: uri, offset: offset))
            let album = response.data?.albumUnion
            return try ValidatedCatalogPage(
                header: album, typename: album?.typename, expectedType: "Album",
                uri: album?.uri, requestedURI: uri, items: album?.tracksV2?.items,
                totalCount: album?.tracksV2?.totalCount)
        }
    }

    // MARK: - Artist

    /// Who the artist is, plus a sample of their discography.
    func artist(id: String) async throws -> PathfinderArtistUnion {
        try await artistUnion(.queryArtistOverview, id: id)
    }

    /// Every release by an artist. Carries no profile — pair it with `artist(id:)`.
    func artistDiscography(id: String) async throws -> CompleteDiscography {
        try await CompleteDiscography.collect { offset in
            let artist = try await artistUnion(.queryArtistDiscographyAll, id: id, offset: offset)
            return try ValidatedCatalogPage(
                header: artist, typename: artist.typename, expectedType: "Artist",
                uri: artist.uri, requestedURI: "spotify:artist:\(id)", items: artist.discography?.all?.items,
                totalCount: artist.discography?.all?.totalCount)
        }
    }

    private func artistUnion(
        _ operation: PathfinderOperation,
        id: String,
        offset: Int = 0
    ) async throws -> PathfinderArtistUnion {
        let response: PathfinderArtistResponse = try await query(
            operation,
            variables: PathfinderArtistVariables(uri: "spotify:artist:\(id)", offset: offset),
        )

        guard let artist = response.data?.artistUnion, artist.typename == "Artist" else {
            throw PartnerAPIError.emptyPayload
        }

        return artist
    }

    // MARK: - Playlist

    /// A playlist's details and all of its contents.
    ///
    /// **One request is one page.** `fetchPlaylist` caps its answer at `limit` items and reports
    /// the real length as `content.totalCount`, so a playlist longer than a page arrives
    /// silently truncated. The Web API path this replaces paginated to the end, and stopping at
    /// the first page hid every item past the 300th — not just from the list, but from removal
    /// and reordering, which can only name an item the app has seen.
    func playlist(id: String) async throws -> CompletePlaylist {
        let uri = "spotify:playlist:\(id)"
        return try await CompletePlaylist.collect { offset in
            let response: PathfinderPlaylistResponse = try await query(
                .fetchPlaylist, variables: PathfinderPlaylistVariables(uri: uri, offset: offset))
            let playlist = response.data?.playlistV2
            return try ValidatedCatalogPage(
                header: playlist, typename: playlist?.typename, expectedType: "Playlist",
                uri: playlist?.uri, requestedURI: uri, items: playlist?.content?.items,
                totalCount: playlist?.content?.totalCount)
        }
    }

    func addToPlaylist(
        playlistId: String,
        trackUris: [String],
        position: PlaylistItemPosition = .bottom,
    ) async throws {
        try await mutate(
            .addToPlaylist,
            variables: PathfinderAddVariables(
                playlistUri: "spotify:playlist:\(playlistId)",
                playlistItemUris: trackUris,
                newPosition: position,
            ),
            result: \.addItemsToPlaylist,
            expected: .added)
    }

    /// Removes the named **occurrences**, not every copy of a track.
    func removeFromPlaylist(playlistId: String, uids: [String]) async throws {
        try await mutate(
            .removeFromPlaylist,
            variables: PathfinderRemoveVariables(
                playlistUri: "spotify:playlist:\(playlistId)",
                uids: uids,
            ),
            result: \.removeItemsFromPlaylist,
            expected: .removed)
    }

    // MARK: - Library

    func playlistLibrary() async throws -> [PlaylistLibraryNode] {
        struct FolderRequest: Sendable {
            let uri: String?
            let ancestors: Set<String>
        }
        // Keep the complete-library contract without serializing every folder's network latency.
        // One work queue bounds concurrency across the whole hierarchy, including nested folders.
        let folders = try await withThrowingTaskGroup(
            of: (FolderRequest, [PathfinderPlaylist]).self
        ) { group in
            var pending = [FolderRequest(uri: nil, ancestors: [])]
            var next = 0
            var active = 0
            var results: [String: [PathfinderPlaylist]] = [:]
            while next < pending.count || active > 0 {
                try Task.checkCancellation()
                while active < 4, next < pending.count {
                    let request = pending[next]
                    next += 1
                    active += 1
                    group.addTask { (request, try await playlistLibraryEntries(folderURI: request.uri)) }
                }
                guard let (request, entities) = try await group.next() else { break }
                active -= 1
                results[request.uri ?? ""] = entities
                for entity in entities where CatalogMapping.item(from: entity) == nil {
                    guard let uri = entity.uri, uri.contains(":folder:") else { continue }
                    guard !request.ancestors.contains(uri), request.ancestors.count < 31 else {
                        throw PartnerAPIError.emptyPayload
                    }
                    pending.append(FolderRequest(uri: uri, ancestors: request.ancestors.union([uri])))
                }
            }
            return results
        }
        func nodes(in key: String) throws -> [PlaylistLibraryNode] {
            try Task.checkCancellation()
            guard let entities = folders[key] else { throw PartnerAPIError.emptyPayload }
            return try entities.compactMap { entity in
                try Task.checkCancellation()
                if let item = CatalogMapping.item(from: entity) { return PlaylistLibraryNode(playlist: item) }
                guard let uri = entity.uri, uri.contains(":folder:") else { return nil }
                return PlaylistLibraryNode(folderURI: uri, title: entity.name ?? "Folder", children: try nodes(in: uri))
            }
        }
        try Task.checkCancellation()
        return try nodes(in: "")
    }

    private func playlistLibraryEntries(folderURI: String?) async throws -> [PathfinderPlaylist] {
        try Task.checkCancellation()
        return try await paginate { offset in
            let response: PathfinderLibraryResponse<PathfinderPlaylist> = try await query(
                .libraryV3,
                variables: PathfinderLibraryVariables(
                    filters: [LibraryFilter.playlists], offset: offset, limit: LibraryFilter.playlistPageLimit,
                    order: "Custom Order", flatten: false, folderUri: folderURI
                )
            )
            guard let page = response.page, page.items != nil else { throw PartnerAPIError.emptyPayload }
            return Pagination.Page(
                items: try page.validatedEntities(), pageEntryCount: page.items?.count ?? 0, totalCount: page.totalCount
            )
        }
    }

    func libraryAlbums() async throws -> [PathfinderAlbum] {
        try await libraryEntities(filter: LibraryFilter.albums)
    }

    func libraryArtists() async throws -> [PathfinderArtist] {
        try await libraryEntities(filter: LibraryFilter.artists)
    }

    /// One `libraryV3` filter, typed to the kind it selects and paginated to the end.
    ///
    /// Generic rather than three near-identical bodies, because the operation genuinely is one
    /// document: only `filters` differs, and the entity type follows from it.
    private func libraryEntities<Entity: Decodable & Sendable>(
        filter: String,
    ) async throws -> [Entity] {
        try await paginate { offset in
            let response: PathfinderLibraryResponse<Entity> = try await query(
                .libraryV3,
                variables: PathfinderLibraryVariables(
                    filters: [filter],
                    offset: offset,
                    limit: LibraryFilter.pageLimit,
                ),
            )

            guard let page = response.page, page.items != nil else {
                throw PartnerAPIError.emptyPayload
            }
            return Pagination.Page(
                items: try page.validatedEntities(),
                pageEntryCount: page.items?.count ?? 0,
                totalCount: page.totalCount
            )
        }
    }

    /// The user's saved tracks, walked to the end.
    ///
    /// **Stopping at the first page hid every liked song past the fiftieth** — a silent
    /// truncation nobody notices until they look for a specific row that never arrives.
    func libraryTracks() async throws -> [PathfinderLibraryTrackItem] {
        try await paginate { offset in
            let response: PathfinderLibraryTracksResponse = try await query(
                .fetchLibraryTracks,
                variables: PathfinderLibraryTracksVariables(offset: offset, limit: 50),
            )

            guard let page = response.page, page.items != nil else {
                throw PartnerAPIError.emptyPayload
            }
            return Pagination.Page(
                items: page.items ?? [],
                pageEntryCount: page.items?.count ?? 0,
                totalCount: page.totalCount
            )
        }
    }

    // MARK: - Home

    /// The start page, in one request.
    ///
    /// Everything the shelves draw arrives inline — names, cover art, artists — so this is the
    /// whole page rather than an index into it. That is the real saving over what it replaced:
    /// `/me/player/recently-played` named its items by uri only, so the strip cost one further
    /// request per album, playlist and artist on it.
    ///
    /// Throws `emptyPayload` when Spotify answers `GenericError`, which it does with HTTP 200
    /// and an otherwise well-formed body.
    func home() async throws -> PathfinderHome {
        let response: PathfinderHomeResponse = try await query(
            .home,
            variables: PathfinderHomeVariables(),
        )

        guard let home = response.home, !home.isError else {
            throw PartnerAPIError.emptyPayload
        }

        return home
    }

    // MARK: - Profile

    /// Who the listener is: id, display name and avatar.
    func profile() async throws -> PathfinderProfile {
        let response: PathfinderProfileResponse = try await query(
            .profileAttributes,
            variables: EmptyVariables(),
        )

        guard let profile = response.profile else {
            throw PartnerAPIError.emptyPayload
        }

        return profile
    }

    /// Only the requested operation can acknowledge a write. Missing or mismatched success
    /// payloads leave the outcome uncertain; a named failure is a definite rejection.
    private func mutate(
        _ operation: PathfinderOperation,
        variables: some Encodable & Sendable,
        result: KeyPath<PathfinderMutationResponse.Payload, PathfinderMutationResponse.Result?>,
        expected: PathfinderMutationResponse.Success,
    ) async throws {
        let response: PathfinderMutationResponse = try await transact(
            operation,
            variables: variables,
            replay: .unsafe,
        )

        guard let typename = response.data?[keyPath: result]?.typename, !typename.isEmpty else {
            throw PartnerAPIError.emptyPayload
        }
        guard let success = PathfinderMutationResponse.Success(rawValue: typename) else {
            throw PartnerAPIError.mutationRejected(operation.name)
        }
        guard success == expected else { throw PartnerAPIError.emptyPayload }
    }

    // MARK: - Transport

    /// One bounded walk for playlist contents, `libraryV3`, and saved tracks.
    private func paginate<Item: Sendable>(
        firstPage: Pagination.Page<Item>? = nil,
        fetchPage: @escaping @Sendable (Int) async throws -> Pagination.Page<Item>
    ) async throws -> [Item] {
        do {
            return try await Pagination.collect(firstPage: firstPage, fetchPage: fetchPage)
        } catch let failure as Pagination.Failure {
            throw PartnerAPIError.pagination(failure)
        }
    }

    /// Generic over the whole envelope rather than over a search payload: `getAlbum` answers
    /// with `data.albumUnion`, not `data.searchV2`, so the shape below `data` is the
    /// operation's business. Search call sites name `PathfinderResponse<…>` and are unchanged.
    func query<Envelope: Decodable & Sendable>(
        _ operation: PathfinderOperation,
        variables: some Encodable & Sendable,
    ) async throws -> Envelope {
        try await transact(operation, variables: variables, replay: .safe)
    }

    private func transact<Envelope: Decodable & Sendable>(
        _ operation: PathfinderOperation,
        variables: some Encodable & Sendable,
        replay: SpotifyTransientRetry.Replay,
    ) async throws -> Envelope {
        let sent = try await credentials.retryingRefusedToken(
            replay: replay,
            prepare: { try await makeRequest(operation, variables: variables) },
            send: { try await send($0, operation: operation) })

        guard sent.status == 200 else {
            throw Self.failure(operation: operation, status: sent.status)
        }

        return try decode(sent.body, operation: operation)
    }

    /// One attempt, reporting the client token it carried so a refusal can name it.
    private func send(
        _ request: URLRequest, operation: PathfinderOperation
    ) async throws -> SpotifyCredentials.Attempt {
        debugLog("PartnerAPI", "[POST] \(Self.endpoint.absoluteString) \(operation.name)")

        try Task.checkCancellation()
        let (data, response) = try await credentials.transport(request)
        guard let http = response as? HTTPURLResponse else {
            throw PartnerAPIError.emptyPayload
        }

        return SpotifyCredentials.Attempt(body: data, http: http, request: request)
    }

    private static func failure(
        operation: PathfinderOperation,
        status: Int,
    ) -> PartnerAPIError {
        debugLog(
            "PartnerAPI",
            "\(operation.name) failed (HTTP \(status)); response omitted"
        )
        return PartnerAPIError.requestFailed(status)
    }

    /// Builds the request body: operation name, variables, and the persisted-query hash. No
    /// query document — Spotify holds it, keyed by that hash.
    func makeRequest(
        _ operation: PathfinderOperation,
        variables: some Encodable & Sendable,
    ) async throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.httpBody = try Self.encodeBody(operation, variables: variables)

        request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try await credentials.sign(&request)

        return request
    }

    static func encodeBody(
        _ operation: PathfinderOperation,
        variables: some Encodable & Sendable,
    ) throws -> Data {
        try JSONEncoder().encode(
            PathfinderRequestBody(
                variables: variables,
                operationName: operation.name,
                extensions: PathfinderExtensions(
                    persistedQuery: PathfinderPersistedQuery(sha256Hash: operation.sha256Hash),
                ),
            ),
        )
    }

    /// GraphQL reports failure in the body with a 200, so the payload has to be inspected even
    /// on success. A retired persisted query is called out by name, because that is the failure
    /// this design invites and "Spotify returned an error" would send the next person hunting.
    func decode<Envelope: Decodable & Sendable>(
        _ data: Data,
        operation: PathfinderOperation,
    ) throws -> Envelope {
        if let envelope = try? JSONDecoder().decode(PathfinderErrorEnvelope.self, from: data),
            let errors = envelope.errors,
            !errors.isEmpty
        {
            let retired = errors.contains { error in
                error.extensions?.code == "PERSISTED_QUERY_NOT_FOUND"
                    || (error.message?.localizedCaseInsensitiveContains("persistedquerynotfound") ?? false)
            }
            if retired {
                throw PartnerAPIError.persistedQueryNotFound(operation.name)
            }
            throw PartnerAPIError.graphQLErrors(operation.name)
        }

        return try JSONDecoder().decode(Envelope.self, from: data)
    }
}
