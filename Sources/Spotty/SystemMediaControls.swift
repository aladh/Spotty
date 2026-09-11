import Foundation
import MediaPlayer
import Observation
import Synchronization

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
    private var publication = SystemMediaPublicationGate()
    private var publishedSemantic: PlaybackSemanticProjection?

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
        publication = SystemMediaPublicationGate()
        publishedSemantic = nil
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
        let semantic = player.semantic
        if publication.admit(snapshot, at: Date(), force: semantic != publishedSemantic) {
            publishedSemantic = semantic
            output.update(snapshot)
        }
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

/// System media interpolates its own elapsed time. Refresh ordinary anchors at most once per
/// second; semantic changes, seeks and position discontinuities publish immediately.
struct SystemMediaPublicationGate {
    private var previous: SystemMediaSnapshot?
    private var publishedAt: Date?

    mutating func admit(_ snapshot: SystemMediaSnapshot?, at now: Date, force: Bool = false) -> Bool {
        let elapsed = publishedAt.map { now.timeIntervalSince($0) } ?? .infinity
        let semanticChanged: Bool
        let discontinuity: Bool
        if let snapshot, let previous {
            semanticChanged =
                snapshot.title != previous.title || snapshot.artist != previous.artist
                || snapshot.duration != previous.duration || snapshot.playing != previous.playing
                || snapshot.canToggle != previous.canToggle || snapshot.canSkip != previous.canSkip
            let projected = previous.position + (previous.playing ? max(0, elapsed) : 0)
            let expected = previous.duration > 0 ? min(previous.duration, projected) : projected
            discontinuity = abs(snapshot.position - expected) > 0.25
        } else {
            semanticChanged = snapshot != previous
            discontinuity = false
        }
        guard publishedAt == nil || force || semanticChanged || discontinuity || elapsed >= 1 else { return false }
        previous = snapshot
        publishedAt = now
        return true
    }
}

@MainActor
final class MacSystemMediaControlsOutput: SystemMediaControlsOutput {
    private let commands = MPRemoteCommandCenter.shared()
    private let info = MPNowPlayingInfoCenter.default()
    private let admission = SystemMediaAdmission()
    private var targets: [(MPRemoteCommand, Any)] = []

    func install(_ handler: @escaping @MainActor @Sendable (SystemMediaCommand) -> Bool) {
        guard targets.isEmpty else { return }
        let bindings: [(MPRemoteCommand, SystemMediaCommand)] = [
            (commands.togglePlayPauseCommand, .toggle), (commands.playCommand, .play),
            (commands.pauseCommand, .pause), (commands.nextTrackCommand, .next),
            (commands.previousTrackCommand, .previous),
        ]
        for (command, action) in bindings {
            let token = command.addTarget { [admission] _ in
                guard let generation = admission.admit(action) else { return .commandFailed }
                // The cached projection admits without blocking MediaPlayer. The store handler
                // revalidates current readiness on MainActor before dispatching any command.
                Task { @MainActor in
                    guard admission.isCurrent(generation) else { return }
                    _ = handler(action)
                }
                return .success
            }
            targets.append((command, token))
        }
    }

    func update(_ snapshot: SystemMediaSnapshot?) {
        admission.update(snapshot)
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

/// Only admission booleans cross the system callback boundary; metadata stays on MainActor.
nonisolated final class SystemMediaAdmission: Sendable {
    private struct State { var toggle = false; var skip = false; var generation: UInt64 = 0 }
    private let state = Mutex(State())

    @MainActor func update(_ snapshot: SystemMediaSnapshot?) {
        state.withLock {
            if snapshot == nil { $0.generation &+= 1 }
            $0.toggle = snapshot?.canToggle ?? false
            $0.skip = snapshot?.canSkip ?? false
        }
    }

    func admit(_ command: SystemMediaCommand) -> UInt64? {
        state.withLock { state in
            let enabled =
                switch command {
                case .toggle, .play, .pause: state.toggle
                case .next, .previous: state.skip
                }
            return enabled ? state.generation : nil
        }
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        state.withLock { $0.generation == generation }
    }
}
