import SpottyDomain
//
//  PathfinderOperations.swift
//  Spotty
//
//  The persisted queries Spotify's own client sends, and their hashes.
//

import Foundation
import SpottyRuntimeContracts

/// Names and hashes select Spotify's stored query documents; requests supply variables only.
/// A replacement hash can change response shape, so update its wire models and fixtures together.
/// Query retirement surfaces as `persistedQueryNotFound`; fixtures do not prove live acceptance.
/// Live checks follow docs/product/safe-testing.md.
///
/// Recorded provenance: libspot's pathfinder/pfrequest/operations.go (2026-05-22), with the album
/// exception noted below. These historical sources are not a current service-compatibility claim.
nonisolated struct PathfinderOperation: Sendable, Equatable {
    let name: String
    let sha256Hash: String

    static let searchTracks = PathfinderOperation(
        name: "searchTracks",
        sha256Hash: "59ee4a659c32e9ad894a71308207594a65ba67bb6b632b183abe97303a51fa55",
    )

    static let searchAlbums = PathfinderOperation(
        name: "searchAlbums",
        sha256Hash: "5e7d2724fbef31a25f714844bf1313ffc748ebd4bd199eaad50628a4f246a7ab",
    )

    static let searchArtists = PathfinderOperation(
        name: "searchArtists",
        sha256Hash: "72c8c7c1e789a9f11e261c4f9ae35a9465bbb90137c584428989573617b6c08d",
    )

    static let searchPlaylists = PathfinderOperation(
        name: "searchPlaylists",
        sha256Hash: "af1730623dc1248b75a61a18bad1f47f1fc7eff802fb0676683de88815c958d8",
    )

    /// Album metadata and one track page. Recorded source: the web-player.765d5916.js bundle
    /// from open.spotifycdn.com, sampled on 2026-08-13.
    static let getAlbum = PathfinderOperation(
        name: "getAlbum",
        sha256Hash: "b9bfabef66ed756e5e13f68a942deb60bd4125ec1f1be8cc42769dc0259b4b10",
    )

    /// Artist profile and sampled discography. Full releases use queryArtistDiscographyAll.
    static let queryArtistOverview = PathfinderOperation(
        name: "queryArtistOverview",
        sha256Hash: "ae0e2958a4ab645b35ca19ac04d0495ae12d9c5d7b7286217674801a9aab281a",
    )

    /// Paginated releases across albums, singles, and compilations, without the profile.
    static let queryArtistDiscographyAll = PathfinderOperation(
        name: "queryArtistDiscographyAll",
        sha256Hash: "5e07d323febb57b4a56a42abbf781490e58764aa45feb6e3dc0591564fc56599",
    )

    /// Metadata and one contents page. This hash also names contents-only and metadata-only
    /// operations; operationName selects the response shape.
    static let fetchPlaylist = PathfinderOperation(
        name: "fetchPlaylist",
        sha256Hash: "86dde7b9d9356e2369414647cf6950cfed96e778e129cfdfc99aea6c1613b3b0",
    )

    /// Playlist mutations share one document but select different operations and acknowledgments.
    static let addToPlaylist = PathfinderOperation(
        name: "addToPlaylist",
        sha256Hash: playlistMutationHash,
    )

    static let removeFromPlaylist = PathfinderOperation(
        name: "removeFromPlaylist",
        sha256Hash: playlistMutationHash,
    )

    private static let playlistMutationHash =
        "47b2a1234b17748d332dd0431534f22450e9ecbb3d5ddcdacbd83368636a0990"

    /// Playlists, albums, and followed artists selected by filters; saved tracks use a separate query.
    static let libraryV3 = PathfinderOperation(
        name: "libraryV3",
        sha256Hash: "390c78e5b951029bad359785e69b07b536a509c581cbcd0aded5e5067f187455",
    )

    /// The listener's saved tracks.
    static let fetchLibraryTracks = PathfinderOperation(
        name: "fetchLibraryTracks",
        sha256Hash: "087278b20b743578a6262c2b0b4bcd20d879c503cc359a2285baf083ef944240",
    )

    /// Greeting and titled shelves, decoded by PathfinderHome.swift. Changing this document
    /// requires checking its selected fields, even when the operation name stays the same.
    static let home = PathfinderOperation(
        name: "home",
        sha256Hash: "23e37f2e58d82d567f27080101d36609009d8c3676457b1086cb0acc55b72a5d",
    )

    /// The listener's profile.
    static let profileAttributes = PathfinderOperation(
        name: "profileAttributes",
        sha256Hash: "08ffb4730af3746e04a8301396f20875dbbce10c75243803091a9274eacc8ac0",
    )
}

/// Encodes an empty object for operations with no declared variables.
nonisolated struct EmptyVariables: Encodable, Sendable {}

/// The variables the artist operations take.
nonisolated struct PathfinderArtistVariables: Encodable, Sendable {
    var uri: String
    var locale: String = ""
    var offset: Int = 0
    var limit: Int = 100
}

/// Album pages use the web client's 300-item request size. `CompleteAlbum` validates the
/// reported total and advances the offset before publishing the complete collection.
nonisolated struct PathfinderAlbumVariables: Encodable, Sendable {
    var uri: String
    var locale: String = ""
    var offset: Int = 0
    var limit: Int = 300
}

/// Search variables include the flags referenced by the stored document; omission is not a default.
/// Recorded source: libspot's defaultSearchCommons.
nonisolated struct PathfinderSearchVariables: Encodable, Sendable {
    var searchTerm: String
    var offset: Int = 0
    var limit: Int = 30
    var numberOfTopResults: Int = 30
    var includePreReleases: Bool = true
    var includeArtistHasConcertsField: Bool = false
    var includeAudiobooks: Bool = true
    var includeAuthors: Bool = true
    var includeEpisodeContentRatingsV2: Bool = false
}
