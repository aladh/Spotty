import SpottyDomain

/// Narrow catalog-facing playback surface. Holds the scene-owned `PlaybackStore` so
/// leaves observe only the computed facts they render. The captured account identity fences
/// actions retained by an older row or menu after the scene adopts a replacement account.
@MainActor
struct CatalogPlaybackAccess {
    private let player: PlaybackStore
    private let renderedAccountEpoch: UInt64

    init(player: PlaybackStore) {
        self.player = player
        renderedAccountEpoch = player.accountEpoch
    }

    private var isCurrentAccount: Bool { player.accountEpoch == renderedAccountEpoch }
    var isConnected: Bool { isCurrentAccount && player.isConnected }
    var accountEpoch: UInt64 { player.accountEpoch }
    var isShuffleEnabled: Bool { player.isShuffleEnabled }

    func toggleShuffle() { if isCurrentAccount { player.toggleShuffle() } }

    var canStartPlayback: Bool { isCurrentAccount && player.canStartPlayback }
    var currentTrackIndicator: CurrentTrackIndicator { player.currentTrackIndicator }
    func isPlayingPlaylist(_ uri: String) -> Bool {
        player.playingContextURI == uri
    }

    var statusText: String { player.statusText }
    var requiresReauthentication: Bool { player.requiresReauthentication }
    var connectionActionTitle: String {
        requiresReauthentication ? "Sign In Again" : "Connect Spotify"
    }

    func connect() {
        guard isCurrentAccount else { return }
        if requiresReauthentication {
            player.reauthorize()
        } else {
            player.connect()
        }
    }

    func playURI(_ uri: String) {
        guard isCurrentAccount else { return }
        player.play(uri: uri)
    }

    func playTrack(_ track: CatalogTrack) {
        guard isCurrentAccount else { return }
        player.play(track: track)
    }

    func playPlaylist(_ item: CatalogItem) {
        guard isCurrentAccount else { return }
        player.playPlaylist(item)
    }

    func addToQueue(_ uris: [String]) {
        guard isCurrentAccount else { return }
        player.addToQueue(uris: uris)
    }
}
