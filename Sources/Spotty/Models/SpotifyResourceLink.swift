import Foundation
import SpottyDomain

/// Strict resource routing. Unknown schemes, lookalike hosts and playback-only resources
/// are ignored, rather than interpreted as a command or sent to a network resolver.
enum SpotifyResourceLink {
    static func item(from url: URL) -> CatalogItem? {
        let components: [String]
        if url.scheme?.lowercased() == "spotify" {
            guard url.query == nil, url.fragment == nil else { return nil }
            let parts = url.absoluteString.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else { return nil }
            components = ["spotify", parts[1], parts[2]]
        } else {
            guard url.scheme?.lowercased() == "https", url.host?.lowercased() == "open.spotify.com",
                url.user == nil, url.password == nil, url.port == nil
            else { return nil }
            var path = url.pathComponents.filter { $0 != "/" }
            if path.first?.hasPrefix("intl-") == true { path.removeFirst() }
            guard path.count == 2 else { return nil }
            components = ["spotify"] + path
        }
        let kind: CatalogItem.Kind
        switch components[1] {
        case "playlist": kind = .playlist
        case "album": kind = .album
        case "artist": kind = .artist
        default: return nil
        }
        guard !components[2].isEmpty, components[2].utf8.count <= 22,
            components[2].utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
            })
        else { return nil }
        let title: String
        switch kind {
        case .playlist: title = "Playlist"
        case .album: title = "Album"
        case .artist: title = "Artist"
        default: return nil
        }
        return CatalogItem(
            id: components[2], uri: components.joined(separator: ":"), title: title,
            subtitle: "", artworkURL: nil, kind: kind)
    }
}
