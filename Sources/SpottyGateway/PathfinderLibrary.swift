//
//  PathfinderLibrary.swift
//  Spotty
//
//  What the library operations send back.
//

// MARK: - libraryV3

/// `{ "data": { "me": { "libraryV3": { … } } } }`
///
/// One query answers what the Web API spread across `/me/playlists`, `/me/albums` and
/// `/me/following?type=artist`: the same document returns whichever kinds `filters` names, and
/// the app asks for one kind at a time because its three library sections are separate screens.
nonisolated struct PathfinderLibraryResponse<Entity: Decodable & Sendable>: Decodable, Sendable {
    struct Me: Decodable, Sendable {
        let libraryV3: PathfinderLibraryPage<Entity>?
    }

    struct Payload: Decodable, Sendable {
        let me: Me?
    }

    let data: Payload?

    var page: PathfinderLibraryPage<Entity>? {
        data?.me?.libraryV3
    }
}

/// A page of library entries.
///
/// **`totalCount` can exceed what the page renders**, so it is what Spotify holds rather than
/// what the list will show — the same mismatch the saved-tracks list lives with, where relinking
/// makes several saved entries resolve to one track. Pagination therefore advances by the item
/// count, never by how many entities survived.
nonisolated struct PathfinderLibraryPage<Entity: Decodable & Sendable>: Decodable, Sendable {
    let totalCount: Int?
    let items: [PathfinderLibraryItem<Entity>]?

    /// The entities, with anything unreadable dropped rather than failing the whole page.
    ///
    /// **Decoding is not a filter.** A playlist *folder* decodes as a `PathfinderPlaylist`
    /// perfectly well — it carries a `uri` and a `name` — so nothing here rejects it, and the
    /// flat catalog reads exclude folders through `flatten` and `PathfinderPlaylist.id`.
    /// The playlist-library reader retains folder entities and loads their children.
    var entities: [Entity] {
        (items ?? []).compactMap(\.item?.data)
    }
}

/// One library entry: when it was added, and the thing that was added.
///
/// The uri sits on the wrapper as `_uri` *beside* the entity rather than inside it, which is why
/// this type exists at all instead of the page holding entities directly. The entity does carry
/// its own `uri` for the three kinds the app stores, so the wrapper's copy is not read — but it
/// is the shape to remember, because `fetchLibraryTracks` below has only the wrapper's.
nonisolated struct PathfinderLibraryItem<Entity: Decodable & Sendable>: Decodable, Sendable {
    struct Wrapper: Decodable, Sendable {
        let data: Entity?
    }

    let addedAt: PathfinderTimestamp?
    let pinned: Bool?
    let item: Wrapper?
}

/// `{ "isoString": "2026-08-13T07:12:40Z" }`, which is how this API spells every timestamp.
nonisolated struct PathfinderTimestamp: Decodable, Sendable {
    let isoString: String?
}

// MARK: - fetchLibraryTracks

/// `{ "data": { "me": { "library": { "tracks": { … } } } } }`
///
/// Saved tracks are *not* part of `libraryV3` — they have their own operation and their own
/// nesting, one level deeper than the rest of the library.
nonisolated struct PathfinderLibraryTracksResponse: Decodable, Sendable {
    struct Library: Decodable, Sendable {
        let tracks: PathfinderLibraryTrackPage?
    }

    struct Me: Decodable, Sendable {
        let library: Library?
    }

    struct Payload: Decodable, Sendable {
        let me: Me?
    }

    let data: Payload?

    var page: PathfinderLibraryTrackPage? {
        data?.me?.library?.tracks
    }
}

nonisolated struct PathfinderLibraryTrackPage: Decodable, Sendable {
    let totalCount: Int?
    let items: [PathfinderLibraryTrackItem]?
}

/// One saved track.
///
/// **The track does not carry its own uri here**, which is the one thing that makes this shape
/// different from every other track-bearing response: `track.data` holds the name, album, artists
/// and duration, and the uri lives on `track._uri` beside it. A decoder that read `data.uri`
/// would get nil for every row and drop the whole list — so the uri is passed into the
/// conversion rather than looked for inside the entity.
nonisolated struct PathfinderLibraryTrackItem: Decodable, Sendable {
    struct Wrapper: Decodable, Sendable {
        let data: PathfinderTrack?

        /// Spotify's own name for the field, underscore included.
        let uri: String?

        private enum CodingKeys: String, CodingKey {
            case data
            case uri = "_uri"
        }
    }

    let addedAt: PathfinderTimestamp?
    let track: Wrapper?
}

// MARK: - Variables

/// The variables `libraryV3` takes.
///
/// **Every field here is optional to Spotify** — the document accepts no variables at all and
/// answers with the whole library. That is a hazard rather than a convenience: an unrecognised
/// filter is *silently ignored* rather than rejected, so a typo returns everything the user has
/// saved instead of an error. Measured by sending `PROBE_INVALID_MEMBER`, which answered HTTP 200
/// with no errors and a full library. Hence `LibraryFilter` — the strings are not spelled at any
/// call site.
/// Flat catalog reads use the defaults. The playlist sidebar requests `Custom Order` (including the space), disables
/// flattening, and pages each `folderUri` to retain Spotify's hierarchy and sibling order.
nonisolated struct PathfinderLibraryVariables: Encodable, Sendable {
    var filters: [String]
    var offset: Int = 0
    var limit: Int = LibraryFilter.pageLimit
    var order: String?
    var textFilter: String = ""
    var flatten: Bool = true
    var expandedFolders: [String] = []
    var folderUri: String?
    var includeFoldersWhenFlattening: Bool = false
}

/// The library kinds this app asks for.
///
/// `Audiobooks` is deliberately absent: the account in testing had two, `libraryV3` will happily
/// return them, and the app has no screen, entity or player path for one. Not asking is the whole
/// of "handling" them — there is no partial support to build, and a placeholder row that cannot
/// be opened would be worse than an absence.
nonisolated enum LibraryFilter {
    static let playlists = "Playlists"
    static let artists = "Artists"
    static let albums = "Albums"

    /// Default request size for flat album and artist reads.
    static let pageLimit = 50

    /// Larger bounded pages reduce startup round trips through playlist folders.
    /// Pagination still advances by returned entries if Spotify caps a response.
    static let playlistPageLimit = 200
}

/// The variables `fetchLibraryTracks` takes. It pages the same way, and reports its own
/// `pagingInfo` back.
nonisolated struct PathfinderLibraryTracksVariables: Encodable, Sendable {
    var offset: Int = 0
    var limit: Int = 50
}
