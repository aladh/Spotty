import Foundation
import SpottyDomain
import SpottyRuntimeContracts

extension BrowsingFixtures {
    /// Banner, long name, portrait fallback, missing art, and empty artist pages.
    var artists: [CatalogItem] {
        ["Harbor Lights", "The Side Streets and the Midnight Orchestra", "Northbound", "Ellis Rowe", "Lena Hart"]
            .enumerated().map { index, name in
                let uri = "spotify:artist:syntheticArtist\(index)"
                return CatalogItem(
                    id: uri, uri: uri, title: name, subtitle: "Artist",
                    artworkURL: index >= 3 ? nil : artworkURLs[index % artworkURLs.count], kind: .artist)
            }
    }

    func artist(id: String) -> CatalogArtistSnapshot? {
        guard let index = artists.firstIndex(where: { $0.uri == "spotify:artist:\(id)" }) else { return nil }
        let item = artists[index]
        let releases = artistReleases(index: index)
        let kinds: [CatalogArtistReleaseKind] = [.album, .single, .ep, .compilation]
        let tracks = (0..<(index == 4 ? 0 : (index == 2 ? 1 : 10))).map { offset in
            let uri = "spotify:track:syntheticArtist\(index)x\(offset)"
            return CatalogArtistPopularTrack(
                track: CatalogTrack(
                    id: uri, uri: uri, title: Self.trackName(at: offset), artist: item.title,
                    album: releases.first?.title ?? "", duration: 183.7 + Double(offset * 11),
                    artworkURL: index >= 3 ? nil : artworkURLs[offset % artworkURLs.count],
                    addedAt: nil, artists: [item], albumItem: releases.first),
                playCount: offset == 4 ? nil : Int64(1_234_567 - offset * 92_341), isPlayable: offset != 3)
        }
        return CatalogArtistSnapshot(
            name: item.title, releases: releases, item: item,
            overview: CatalogArtistOverview(
                headerArtworkURL: index < 2 ? item.artworkURL : nil,
                monthlyListeners: index < 3 ? 1_234_567 : nil, isVerified: index < 2,
                popularTracks: tracks, popularReleases: Array(releases.prefix(6))),
            releaseKinds: Dictionary(
                uniqueKeysWithValues: releases.enumerated().map { ($0.element.uri, kinds[$0.offset % kinds.count]) }),
            releaseDates: Dictionary(
                uniqueKeysWithValues: releases.enumerated().map { ($0.element.uri, "\(2026 - $0.offset / 3)-08-21") }))
    }

    func artistReleases(index: Int) -> [CatalogItem] {
        let kinds: [CatalogArtistReleaseKind] = [.album, .single, .ep, .compilation]
        return (0..<(index == 4 ? 0 : 12)).map { offset in
            let uri = "spotify:album:syntheticArtistRelease\(index)x\(offset)"
            return CatalogItem(
                id: uri, uri: uri, title: Self.albumName(at: offset),
                subtitle: "\(2026 - offset / 3) • \(kinds[offset % kinds.count].label)",
                artworkURL: index >= 3 ? nil : artworkURLs[offset % artworkURLs.count], kind: .album)
        }
    }

    func artistAlbum(id: String) -> CatalogAlbumSnapshot? {
        for index in artists.indices {
            guard let item = artistReleases(index: index).first(where: { $0.uri == "spotify:album:\(id)" }) else {
                continue
            }
            let tracks = (0..<8).map { offset in
                let uri = "spotify:track:\(id)x\(offset)"
                return CatalogTrack(
                    id: uri, uri: uri, title: Self.trackName(at: offset), artist: artists[index].title,
                    album: item.title, duration: 180, artworkURL: item.artworkURL, addedAt: nil,
                    artists: [artists[index]], albumItem: item)
            }
            return CatalogAlbumSnapshot(
                tracks: tracks, releaseDate: "2026-08-21", item: item,
                playCounts: Dictionary(
                    uniqueKeysWithValues: tracks.enumerated().map {
                        ($0.element.uri, Int64(3_129_748_382 - $0.offset * 92_341))
                    }))
        }
        return nil
    }
}
