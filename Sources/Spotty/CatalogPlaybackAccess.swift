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

    var connectionLoadingLabel: String? {
        guard isCurrentAccount, !player.isConnected else { return nil }
        switch player.phase {
        case .authorizing, .connecting, .recovering: return player.statusText
        case .signedOut, .ready, .failed: return nil
        }
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

    func startURIFromBeginning(_ uri: String) {
        guard isCurrentAccount else { return }
        player.play(uri: uri)
    }

    fileprivate func playTrack(_ track: CatalogTrack) {
        guard isCurrentAccount else { return }
        player.play(track: track)
    }

    fileprivate func canActivateTrack(_ track: CatalogTrack, isPlayable: Bool = true) -> Bool {
        guard isCurrentAccount else { return false }
        if player.trackURI == track.uri {
            return (isPlayable || player.isPlaying) && player.canTogglePlayback
        }
        return isPlayable && player.canStartPlayback
    }

    /// A row targets its own track even if playback changes while the control is retained.
    fileprivate func activateTrack(_ track: CatalogTrack, isPlayable: Bool = true) {
        guard isCurrentAccount else { return }
        player.activateTrack(track, isPlayable: isPlayable)
    }

    fileprivate func playPlaylist(_ item: CatalogItem) {
        guard isCurrentAccount else { return }
        player.playPlaylist(item)
    }

    private func isCurrentItem(_ item: CatalogItem) -> Bool {
        item.kind == .track ? player.trackURI == item.uri : player.playingContextURI == item.uri
    }

    fileprivate func showsPause(for item: CatalogItem) -> Bool {
        isConnected && isCurrentItem(item) && player.showsPauseControl
    }

    fileprivate func canActivateItem(_ item: CatalogItem) -> Bool {
        guard isCurrentAccount else { return false }
        return isCurrentItem(item) ? player.canTogglePlayback : player.canStartPlayback
    }

    fileprivate func activateItem(_ item: CatalogItem) {
        guard isCurrentAccount else { return }
        player.activateItem(item)
    }

    func addToQueue(_ uris: [String]) {
        guard isCurrentAccount else { return }
        player.addToQueue(uris: uris)
    }

    func action(for item: CatalogItem, behavior: CatalogPlaybackBehavior) -> CatalogPlaybackAction {
        CatalogPlaybackAction(access: self, target: .item(item), behavior: behavior)
    }

    func action(
        for track: CatalogTrack, behavior: CatalogPlaybackBehavior, isPlayable: Bool = true
    ) -> CatalogPlaybackAction {
        CatalogPlaybackAction(access: self, target: .track(track, isPlayable: isPlayable), behavior: behavior)
    }
}

/// Restarting is a deliberate product action, never an accidental alternative spelling of Play.
enum CatalogPlaybackBehavior {
    case activateSelection
    case startFromBeginning
}

/// A control receives its target, presentation, availability and dispatch together. Computed
/// facts stay observable, and dispatch revalidates the rendered account and runtime authority.
@MainActor
struct CatalogPlaybackAction {
    fileprivate enum Target {
        case item(CatalogItem)
        case track(CatalogTrack, isPlayable: Bool)
    }

    fileprivate let access: CatalogPlaybackAccess
    fileprivate let target: Target
    let behavior: CatalogPlaybackBehavior

    var isEnabled: Bool {
        switch (behavior, target) {
        case let (.activateSelection, .item(item)): access.canActivateItem(item)
        case let (.activateSelection, .track(track, playable)): access.canActivateTrack(track, isPlayable: playable)
        case (.startFromBeginning, .item): access.canStartPlayback
        case let (.startFromBeginning, .track(_, playable)): playable && access.canStartPlayback
        }
    }

    var showsPause: Bool {
        guard behavior == .activateSelection else { return false }
        switch target {
        case let .item(item): return access.showsPause(for: item)
        case let .track(track, _):
            let indicator = access.currentTrackIndicator
            return access.isConnected && indicator.trackURI == track.uri && indicator.isPlaying
        }
    }

    var label: String {
        let title: String
        switch target {
        case let .item(item): title = item.title
        case let .track(track, _): title = track.title
        }
        return "\(showsPause ? "Pause" : "Play") \(title)"
    }

    func perform() {
        switch (behavior, target) {
        case let (.activateSelection, .item(item)): access.activateItem(item)
        case let (.activateSelection, .track(track, playable)): access.activateTrack(track, isPlayable: playable)
        case let (.startFromBeginning, .item(item)):
            if item.kind == .playlist { access.playPlaylist(item) } else { access.startURIFromBeginning(item.uri) }
        case let (.startFromBeginning, .track(track, playable)):
            if playable { access.playTrack(track) }
        }
    }
}
