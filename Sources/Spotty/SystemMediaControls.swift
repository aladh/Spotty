import Foundation
import MediaPlayer
import Observation

/// The system boundary is injected so tests and the isolated demo never claim media keys.
@MainActor
protocol SystemMediaControlsOutput: AnyObject {
    func install(_ handler: @escaping @MainActor @Sendable (SystemMediaCommand) -> Bool)
    func update(_ snapshot: SystemMediaSnapshot?)
    func remove()
}

enum SystemMediaCommand: Sendable {
    case toggle, play, pause, next, previous
}

struct SystemMediaSnapshot: Equatable {
    let title: String
    let artist: String
    let duration: TimeInterval
    let position: TimeInterval
    let playing: Bool
    let canToggle: Bool
    let canSkip: Bool
}

/// App-owned projection and command adapter; the playback store remains the state/effect owner.
@MainActor
final class SystemMediaControls {
    private let player: PlaybackStore
    private let output: any SystemMediaControlsOutput
    private var running = false

    init(player: PlaybackStore, output: any SystemMediaControlsOutput) {
        self.player = player
        self.output = output
    }

    func start() {
        guard !running else { return }
        running = true
        output.install { [weak self] command in self?.handle(command) ?? false }
        observe()
    }

    func stop() {
        guard running else { return }
        running = false
        output.remove()
    }

    private func observe() {
        guard running else { return }
        let snapshot = withObservationTracking {
            guard player.isConnected, !player.isTearingDown, player.hasCurrentTrack else {
                return Optional<SystemMediaSnapshot>.none
            }
            return SystemMediaSnapshot(
                title: player.displayedTrackTitle, artist: player.displayedArtistName,
                duration: player.duration, position: player.displayedPosition(at: Date()),
                playing: player.isPlaying, canToggle: player.canTogglePlayback,
                canSkip: player.canSkipTrack)
        } onChange: { [weak self] in
            // Observation fires before mutation. Re-read after the accepted store update finishes.
            DispatchQueue.main.async { [weak self] in self?.observe() }
        }
        output.update(snapshot)
    }

    private func handle(_ command: SystemMediaCommand) -> Bool {
        guard running else { return false }
        switch command {
        case .toggle, .play, .pause:
            guard player.canTogglePlayback else { return false }
            if command == .play && player.isPlaying { return true }
            if command == .pause && !player.isPlaying { return true }
            player.togglePlayback()
        case .next, .previous:
            guard player.canSkipTrack else { return false }
            if command == .next { player.next() } else { player.previous() }
        }
        return true
    }
}

@MainActor
final class MacSystemMediaControlsOutput: SystemMediaControlsOutput {
    private let commands = MPRemoteCommandCenter.shared()
    private let info = MPNowPlayingInfoCenter.default()
    private var targets: [(MPRemoteCommand, Any)] = []

    func install(_ handler: @escaping @MainActor @Sendable (SystemMediaCommand) -> Bool) {
        guard targets.isEmpty else { return }
        let bindings: [(MPRemoteCommand, SystemMediaCommand)] = [
            (commands.togglePlayPauseCommand, .toggle), (commands.playCommand, .play),
            (commands.pauseCommand, .pause), (commands.nextTrackCommand, .next),
            (commands.previousTrackCommand, .previous),
        ]
        for (command, action) in bindings {
            let token = command.addTarget { _ in
                // MediaPlayer callbacks are not actor-isolated. Return admission synchronously
                // after checking the current store, rather than queueing stale playback actions.
                let accepted: Bool
                if Thread.isMainThread {
                    accepted = MainActor.assumeIsolated { handler(action) }
                } else {
                    accepted = DispatchQueue.main.sync { handler(action) }
                }
                return accepted ? .success : .commandFailed
            }
            targets.append((command, token))
        }
    }

    func update(_ snapshot: SystemMediaSnapshot?) {
        commands.togglePlayPauseCommand.isEnabled = snapshot?.canToggle ?? false
        commands.playCommand.isEnabled = snapshot?.canToggle == true && snapshot?.playing == false
        commands.pauseCommand.isEnabled = snapshot?.canToggle == true && snapshot?.playing == true
        commands.nextTrackCommand.isEnabled = snapshot?.canSkip ?? false
        commands.previousTrackCommand.isEnabled = snapshot?.canSkip ?? false
        guard let snapshot else {
            info.playbackState = .stopped
            info.nowPlayingInfo = nil
            return
        }
        info.nowPlayingInfo = [
            MPMediaItemPropertyTitle: snapshot.title,
            MPMediaItemPropertyArtist: snapshot.artist,
            MPMediaItemPropertyPlaybackDuration: snapshot.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.position,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.playing ? 1.0 : 0.0,
        ]
        info.playbackState = snapshot.playing ? .playing : .paused
    }

    func remove() {
        for (command, token) in targets { command.removeTarget(token) }
        targets.removeAll()
        update(nil)
    }
}
