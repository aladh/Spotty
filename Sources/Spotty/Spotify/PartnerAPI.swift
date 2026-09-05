//
//  PartnerAPI.swift
//  Spotty
//
//  The GraphQL API the desktop client uses, at api-partner.spotify.com.
//

import Foundation
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

/// What a pathfinder *write* answers with, on both the playlist and the library operations.
///
/// **A rejected mutation arrives as HTTP 200**, naming the failure in a `__typename` rather than
/// in a status code — `{"addItemsToPlaylist":{"__typename":"NotFound"}}` for a playlist that does
/// not exist. A client checking only the status would record the write as having happened and
/// never roll back its optimistic update. So success is recognised by name, and anything else is
/// a failure.
nonisolated struct PathfinderMutationResult: Decodable, Sendable {
    let typename: String?
    let message: String?

    private enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case message
    }

    /// Nil when the mutation succeeded, otherwise what went wrong.
    ///
    /// Takes an optional because a response that named no result at all is itself a failure —
    /// an absent payload is not a write that happened.
    static func failure(_ result: Self?, unless successTypes: Set<String>) -> String? {
        guard let result, let typename = result.typename else {
            return "the response named no result"
        }
        guard !successTypes.contains(typename) else { return nil }

        return result.message.map { "\(typename): \($0)" } ?? typename
    }
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

    // MARK: - Searches

    func searchTracks(_ term: String, limit: Int = 30) async throws -> [PathfinderTrack] {
        let response: PathfinderResponse<PathfinderTrackResults> = try await query(
            .searchTracks,
            variables: PathfinderSearchVariables(searchTerm: term, limit: limit),
        )
        return response.results?.tracksV2?.entities ?? []
    }

    func searchAlbums(_ term: String, limit: Int = 30) async throws -> [PathfinderAlbum] {
        let response: PathfinderResponse<PathfinderAlbumResults> = try await query(
            .searchAlbums,
            variables: PathfinderSearchVariables(searchTerm: term, limit: limit),
        )
        return response.results?.albumsV2?.entities ?? []
    }

    func searchArtists(_ term: String, limit: Int = 30) async throws -> [PathfinderArtist] {
        let response: PathfinderResponse<PathfinderArtistResults> = try await query(
            .searchArtists,
            variables: PathfinderSearchVariables(searchTerm: term, limit: limit),
        )
        return response.results?.artists?.entities ?? []
    }

    func searchPlaylists(_ term: String, limit: Int = 30) async throws -> [PathfinderPlaylist] {
        let response: PathfinderResponse<PathfinderPlaylistResults> = try await query(
            .searchPlaylists,
            variables: PathfinderSearchVariables(searchTerm: term, limit: limit),
        )
        return response.results?.playlists?.entities ?? []
    }

    // MARK: - Album

    /// An album's details *and* its track list, in one request.
    ///
    /// The Web API needed two — `/albums/{id}` and `/albums/{id}/tracks` — and this replaces
    /// both. spclient can also answer albums, but its `disc[].track[]` entries carry a `gid`
    /// and nothing else, so rendering one album would cost a request per track; measured
    /// against Discovery, that is fifteen requests instead of one.
    func album(id: String) async throws -> PathfinderAlbumUnion {
        let response: PathfinderAlbumResponse = try await query(
            .getAlbum,
            variables: PathfinderAlbumVariables(uri: "spotify:album:\(id)"),
        )

        guard let album = response.data?.albumUnion else {
            throw PartnerAPIError.emptyPayload
        }

        return album
    }

    // MARK: - Artist

    /// Who the artist is, plus a sample of their discography.
    func artist(id: String) async throws -> PathfinderArtistUnion {
        try await artistUnion(.queryArtistOverview, id: id)
    }

    /// Every release by an artist. Carries no profile — pair it with `artist(id:)`.
    func artistDiscography(id: String) async throws -> PathfinderArtistUnion {
        try await artistUnion(.queryArtistDiscographyAll, id: id)
    }

    private func artistUnion(
        _ operation: PathfinderOperation,
        id: String,
    ) async throws -> PathfinderArtistUnion {
        let response: PathfinderArtistResponse = try await query(
            operation,
            variables: PathfinderArtistVariables(uri: "spotify:artist:\(id)"),
        )

        guard let artist = response.data?.artistUnion else {
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
    func playlist(id: String) async throws -> PathfinderPlaylistUnion {
        let uri = "spotify:playlist:\(id)"
        let first = try await playlistPage(uri: uri, offset: 0)
        let total = first.content?.totalCount
        let items: [PathfinderPlaylistItem] = try await paginate(
            firstPage: Pagination.Page(
                items: first.content?.items ?? [],
                pageEntryCount: first.content?.items?.count ?? 0,
                totalCount: total
            )
        ) { offset in
            let page = try await playlistPage(uri: uri, offset: offset)
            return Pagination.Page(
                items: page.content?.items ?? [],
                pageEntryCount: page.content?.items?.count ?? 0,
                totalCount: total
            )
        }
        return first.withItems(items)
    }

    private func playlistPage(uri: String, offset: Int) async throws -> PathfinderPlaylistUnion {
        let response: PathfinderPlaylistResponse = try await query(
            .fetchPlaylist,
            variables: PathfinderPlaylistVariables(uri: uri, offset: offset),
        )

        guard let playlist = response.data?.playlistV2 else {
            throw PartnerAPIError.emptyPayload
        }

        return playlist
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
            ))
    }

    /// Removes the named **occurrences**, not every copy of a track.
    func removeFromPlaylist(playlistId: String, uids: [String]) async throws {
        try await mutate(
            .removeFromPlaylist,
            variables: PathfinderRemoveVariables(
                playlistUri: "spotify:playlist:\(playlistId)",
                uids: uids,
            ))
    }

    // MARK: - Library

    /// The user's saved playlists, walked to the end.
    ///
    /// Decoded entities can be fewer than what the pages carried. See
    /// `PathfinderLibraryPage`, and `Pagination` for why walks advance by page entries rather
    /// than by decoded entities.
    func libraryPlaylists() async throws -> [PathfinderPlaylist] {
        try await libraryEntities(filter: LibraryFilter.playlists)
    }

    func playlistLibrary() async throws -> [PlaylistLibraryNode] {
        try await playlistLibrary(folderURI: nil, ancestors: [])
    }

    private func playlistLibrary(folderURI: String?, ancestors: Set<String>) async throws -> [PlaylistLibraryNode] {
        try Task.checkCancellation()
        guard ancestors.count < 32 else { throw PartnerAPIError.emptyPayload }
        let entities: [PathfinderPlaylist] = try await paginate { offset in
            let response: PathfinderLibraryResponse<PathfinderPlaylist> = try await query(
                .libraryV3,
                variables: PathfinderLibraryVariables(
                    filters: [LibraryFilter.playlists], offset: offset,
                    order: "Custom Order", flatten: false, folderUri: folderURI
                )
            )
            guard let page = response.page else { throw PartnerAPIError.emptyPayload }
            return Pagination.Page(
                items: page.entities, pageEntryCount: page.items?.count ?? 0, totalCount: page.totalCount)
        }
        var nodes: [PlaylistLibraryNode] = []
        for entity in entities {
            try Task.checkCancellation()
            if let item = CatalogMapping.item(from: entity) {
                nodes.append(PlaylistLibraryNode(playlist: item))
            } else if let uri = entity.uri, uri.contains(":folder:") {
                guard !ancestors.contains(uri) else { throw PartnerAPIError.emptyPayload }
                let children = try await playlistLibrary(folderURI: uri, ancestors: ancestors.union([uri]))
                nodes.append(PlaylistLibraryNode(folderURI: uri, title: entity.name ?? "Folder", children: children))
            }
        }
        return nodes
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

            guard let page = response.page else {
                throw PartnerAPIError.emptyPayload
            }
            return Pagination.Page(
                items: page.entities,
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

            guard let page = response.page else {
                throw PartnerAPIError.emptyPayload
            }
            return Pagination.Page(
                items: page.items ?? [],
                pageEntryCount: page.items?.count ?? 0,
                totalCount: page.totalCount
            )
        }
    }

    /// Which of these are in the library, keyed by id.
    ///
    /// A uri the service does not answer for is **left out** rather than reported false, so a
    /// truncated response leaves a track unresolved and asked about again instead of cached as
    /// "not saved".
    func entitiesInLibrary(uris: [String]) async throws -> [String: Bool] {
        guard !uris.isEmpty else { return [:] }

        let response: PathfinderLibraryMembershipResponse = try await query(
            .areEntitiesInLibrary,
            variables: PathfinderLibraryLookupVariables(uris: uris),
        )

        return response.statuses(for: uris)
    }

    /// Saves anything — a track, an album, an artist — by uri.
    func addToLibrary(uris: [String]) async throws {
        try await mutateLibrary(.addToLibrary, uris: uris)
    }

    func removeFromLibrary(uris: [String]) async throws {
        try await mutateLibrary(.removeFromLibrary, uris: uris)
    }

    private func mutateLibrary(_ operation: PathfinderOperation, uris: [String]) async throws {
        guard !uris.isEmpty else { return }

        let response: PathfinderLibraryMutationResponse = try await transact(
            operation,
            variables: PathfinderLibraryWriteVariables(libraryItemUris: uris),
            replay: .unsafe,
        )

        if response.failure != nil {
            throw PartnerAPIError.mutationRejected(operation.name)
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

    /// Runs a mutation and throws unless the response says it happened.
    ///
    /// A rejected mutation arrives as HTTP 200 with a `__typename` naming the failure, so the
    /// transport's status check cannot see it — without this, a failed write would look like a
    /// successful one and the optimistic update would stand.
    private func mutate(
        _ operation: PathfinderOperation,
        variables: some Encodable & Sendable,
    ) async throws {
        let response: PathfinderMutationResponse = try await transact(
            operation,
            variables: variables,
            replay: .unsafe,
        )

        if response.failure != nil {
            throw PartnerAPIError.mutationRejected(operation.name)
        }
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
        let sent = try await credentials.retryingRefusedToken(replay: replay) {
            try await send(operation, variables: variables)
        }

        guard sent.status == 200 else {
            throw Self.failure(operation: operation, status: sent.status)
        }

        return try decode(sent.body, operation: operation)
    }

    /// One attempt, reporting the client token it carried so a refusal can name it.
    private func send(
        _ operation: PathfinderOperation,
        variables: some Encodable & Sendable,
    ) async throws -> SpotifyCredentials.Attempt {
        let request = try await makeRequest(operation, variables: variables)

        debugLog("PartnerAPI", "[POST] \(Self.endpoint.absoluteString) \(operation.name)")

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
