enum SidebarDestination: String, Sendable {
    case home = "Home"
    case search = "Search"
    case liked = "Liked Songs"
    case albums = "Albums"
    case artists = "Artists"
    case playlists = "Playlists"
}

enum SidebarSelection: Hashable {
    case destination(SidebarDestination)
    case playlist(String)
    case album(String)
    case artist(String)
    case discography(String)
}

extension SidebarSelection: RawRepresentable {
    init?(rawValue: String) {
        if rawValue.hasPrefix("playlist:") {
            self = .playlist(String(rawValue.dropFirst("playlist:".count)))
        } else if rawValue.hasPrefix("album:") {
            self = .album(String(rawValue.dropFirst("album:".count)))
        } else if rawValue.hasPrefix("artist:") {
            self = .artist(String(rawValue.dropFirst("artist:".count)))
        } else if rawValue.hasPrefix("discography:") {
            self = .discography(String(rawValue.dropFirst("discography:".count)))
        } else if rawValue.hasPrefix("destination:"),
            let destination = SidebarDestination(
                rawValue: String(rawValue.dropFirst("destination:".count))
            )
        {
            self = .destination(destination)
        } else {
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case let .destination(destination):
            "destination:\(destination.rawValue)"
        case let .playlist(uri):
            "playlist:\(uri)"
        case let .album(uri):
            "album:\(uri)"
        case let .artist(uri):
            "artist:\(uri)"
        case let .discography(uri):
            "discography:\(uri)"
        }
    }

    /// Privacy-safe diagnostic category. Spotify entity identifiers are user data and add no
    /// value when diagnosing a navigation transition.
    var diagnosticLabel: String {
        switch self {
        case let .destination(destination): "destination:\(destination.rawValue)"
        case .playlist: "media:playlist"
        case .album: "media:album"
        case .artist: "media:artist"
        case .discography: "media:discography"
        }
    }
}
