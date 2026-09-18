import SpottyDomain
//
//  PathfinderArtist.swift
//  Spotty
//
//  What the artist operations send back.
//

import Foundation
import SpottyRuntimeContracts

/// `{ "data": { "artistUnion": { … } } }`
///
/// Shared by `queryArtistOverview` and `queryArtistDiscographyAll`, which return the same
/// envelope with different parts filled in — the overview brings a profile and a sampled
/// discography, the discography query brings `discography.all` and nothing else.
nonisolated struct PathfinderArtistResponse: Decodable, Sendable {
    struct Payload: Decodable, Sendable {
        let artistUnion: PathfinderArtistUnion?
    }

    let data: Payload?
}

/// # Genres
///
/// **There are none, anywhere.** Measured on 2026-08-13 against `queryArtistOverview`,
/// `queryArtistDiscographyAll`, `queryArtistMinimal` and spclient's `metadata/4/artist` — the
/// Web API's `/artists/{id}` returns `genres` and none of the client's own APIs do. Spotify's
/// own artist pages do not show them either. So `Artist` no longer carries a genre list; the
/// row that displayed one is gone rather than permanently empty.
nonisolated struct PathfinderArtistUnion: Decodable, Sendable {
    struct Profile: Decodable, Sendable {
        struct Biography: Decodable, Sendable { let text: String? }
        let name: String?
        var biography: Biography? = nil
        var playlistsV2: PathfinderItems<PathfinderPlaylist>? = nil
    }

    struct Visuals: Decodable, Sendable {
        struct Gallery: Decodable, Sendable { let items: [PathfinderImage]? }
        let avatarImage: PathfinderImage?
        var gallery: Gallery? = nil
    }

    struct HeaderImage: Decodable, Sendable {
        struct Image: Decodable, Sendable {
            struct Source: Decodable, Sendable {
                let url: String?
                let maxWidth: Int?
            }
            let sources: [Source]?
            var largestURL: String? { sources?.max { ($0.maxWidth ?? 0) < ($1.maxWidth ?? 0) }?.url }
        }
        let data: Image?
    }

    struct Stats: Decodable, Sendable {
        let monthlyListeners: Int?
        var followers: Int? = nil
    }

    struct Reputation: Decodable, Sendable {
        struct Verification: Decodable, Sendable {
            let isVerified: Bool?
        }
        let verification: Verification?
    }

    struct RelatedContent: Decodable, Sendable {
        let featuringV2: PathfinderItems<PathfinderPlaylist>?
        var discoveredOnV2: PathfinderItems<PathfinderPlaylist>? = nil
    }

    struct TopTracks: Decodable, Sendable {
        struct Item: Decodable, Sendable {
            let track: Track?
        }
        struct Track: Decodable, Sendable {
            struct Playability: Decodable, Sendable { let playable: Bool? }
            let metadata: PathfinderTrack
            let playcount: String?
            let playability: Playability?

            private enum CodingKeys: String, CodingKey { case playcount, playability }
            init(from decoder: any Decoder) throws {
                metadata = try PathfinderTrack(from: decoder)
                let values = try decoder.container(keyedBy: CodingKeys.self)
                playcount = try values.decodeIfPresent(String.self, forKey: .playcount)
                playability = try values.decodeIfPresent(Playability.self, forKey: .playability)
            }
        }
        let items: [Item]?
    }

    /// The discography, whichever operation filled it in.
    ///
    /// The overview splits releases into `albums`, `singles` and `compilations`, each holding
    /// a sample; `queryArtistDiscographyAll` puts every release in `all`. The app shows one
    /// list, so it reads `all` and falls back to the sampled sections.
    struct Discography: Decodable, Sendable {
        let all: PathfinderReleaseGroup?
        let albums: PathfinderReleaseGroup?
        let singles: PathfinderReleaseGroup?
        let compilations: PathfinderReleaseGroup?
        var popularReleasesAlbums: PathfinderReleaseGroup? = nil
        var topTracks: TopTracks? = nil
    }

    let uri: String?
    let id: String?
    let profile: Profile?
    let visuals: Visuals?
    let discography: Discography?
    // These fields were verified against the stored overview query on 2026-09-15.
    var headerImage: HeaderImage? = nil
    var stats: Stats? = nil
    var onPlatformReputationTrait: Reputation? = nil
    // Verified against queryArtistOverview and the desktop Featuring row on 2026-09-16.
    var relatedContent: RelatedContent? = nil
    var typename: String? = nil

    private enum CodingKeys: String, CodingKey {
        case uri, id, profile, visuals, discography, headerImage, stats, onPlatformReputationTrait, relatedContent
        case typename = "__typename"
    }

    var artistId: String? {
        id ?? uri.flatMap(SpotifyURI.id(from:))
    }

    func withDiscographyItems(_ items: [PathfinderReleaseGroup.Item]) -> Self {
        Self(
            uri: uri, id: id, profile: profile, visuals: visuals,
            discography: Discography(
                all: PathfinderReleaseGroup(items: items, totalCount: discography?.all?.totalCount),
                albums: nil, singles: nil, compilations: nil),
            headerImage: headerImage, stats: stats, onPlatformReputationTrait: onPlatformReputationTrait,
            relatedContent: relatedContent, typename: typename)
    }

    /// Every release this response carries, in order, deduplicated by id.
    ///
    /// Sections overlap — `popularReleasesAlbums` repeats entries from `albums` — so a page
    /// built from more than one of them would otherwise list the same album twice, which for a
    /// SwiftUI `ForEach` keyed by album id is undefined behaviour rather than a repeated row.
    var releases: [PathfinderRelease] {
        let groups = [
            discography?.all,
            discography?.albums,
            discography?.singles,
            discography?.compilations,
        ]

        var seen = Set<String>()
        return groups.compactMap(\.self).flatMap(\.releases).filter { release in
            guard let id = release.releaseId else { return false }
            return seen.insert(id).inserted
        }
    }
}

/// One section of a discography.
///
/// **Two item shapes, again.** Most sections wrap each entry as `items[].releases.items[]` —
/// a release *group*, which can hold several editions of one record. But
/// `popularReleasesAlbums` puts the release fields directly on `items[]` with no wrapper. Both
/// are accepted rather than switched on per section, for the same reason `PathfinderItems`
/// accepts both search shapes: the difference belongs to Spotify's stored queries, and the next
/// section added is as likely to take either form.
nonisolated struct PathfinderReleaseGroup: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        /// What this entry holds: a whole group's releases, or the single release the entry
        /// itself turned out to be.
        let all: [PathfinderRelease]

        private struct Group: Decodable {
            struct Releases: Decodable {
                let items: [PathfinderRelease]?
            }

            let releases: Releases?
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()

            if let group = try? container.decode(Group.self), let releases = group.releases {
                all = releases.items ?? []
            } else if let release = try? container.decode(PathfinderRelease.self) {
                all = [release]
            } else {
                all = []
            }
        }
    }

    let items: [Item]?
    let totalCount: Int?

    var releases: [PathfinderRelease] {
        (items ?? []).flatMap(\.all)
    }
}

/// One release — an album, single or compilation — as a discography lists it.
nonisolated struct PathfinderRelease: Decodable, Sendable {
    /// **The date shape differs by operation**, which a single decoder has to absorb:
    /// `queryArtistOverview` sends `{day, month, year, precision}` while
    /// `queryArtistDiscographyAll` sends `{isoString, year, precision}`. Only `year` is in both,
    /// and the artist page renders a year — so the day-level fields are assembled when present
    /// and the year used otherwise.
    struct ReleaseDate: Decodable, Sendable {
        let isoString: String?
        let year: Int?
        let month: Int?
        let day: Int?

        /// A `YYYY-MM-DD` string where the parts allow, the bare year otherwise.
        var formatted: String? {
            if let isoString {
                return String(isoString.prefix(while: { $0 != "T" }))
            }
            if let year, let month, let day {
                return String(format: "%04d-%02d-%02d", year, month, day)
            }
            return year.map(String.init)
        }
    }

    struct TrackCount: Decodable, Sendable {
        let totalCount: Int?
    }

    let uri: String?
    let id: String?
    let name: String?
    let type: String?
    let date: ReleaseDate?
    let coverArt: PathfinderImage?
    let tracks: TrackCount?

    var releaseId: String? {
        id ?? uri.flatMap(SpotifyURI.id(from:))
    }
}
