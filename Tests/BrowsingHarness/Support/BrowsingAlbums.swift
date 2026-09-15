import Foundation
import SpottyDomain
import SpottyRuntimeContracts

extension BrowsingFixtures {
    /// Normal, long-title, single-song, missing-artwork, and empty releases.
    var albums: [CatalogItem] {
        [0, 2, 4, 5, 8].enumerated().map { index, nameIndex in
            let uri = "spotify:album:syntheticAlbum\(index)"
            return CatalogItem(
                id: uri, uri: uri, title: Self.albumName(at: nameIndex),
                subtitle: Self.artistName(at: nameIndex),
                artworkURL: index == 3 ? nil : artworkURLs[index % artworkURLs.count], kind: .album)
        }
    }

    func album(id: String) -> CatalogAlbumSnapshot? {
        guard let index = albums.firstIndex(where: { $0.uri == "spotify:album:\(id)" }) else { return nil }
        let item = albums[index]
        let count = index == 4 ? 0 : (index == 2 ? 1 : 12)
        let artist = CatalogItem(
            id: "syntheticArtist\(index)", uri: "spotify:artist:syntheticArtist\(index)",
            title: item.subtitle, subtitle: "Artist", artworkURL: item.artworkURL, kind: .artist)
        let tracks = (0..<count).map { offset in
            let uri = "spotify:track:syntheticAlbum\(index)x\(offset)"
            return CatalogTrack(
                id: uri, uri: uri, title: Self.trackName(at: offset), artist: item.subtitle,
                album: item.title, duration: 180 + Double(offset * 7), artworkURL: item.artworkURL,
                addedAt: nil, artists: [artist], albumItem: item)
        }
        return CatalogAlbumSnapshot(tracks: tracks, releaseDate: "2026-08-21", item: item)
    }
}
