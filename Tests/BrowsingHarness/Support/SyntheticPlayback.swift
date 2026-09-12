import Foundation
import SpottyDomain
import SpottyEngineAdapter
import SpottyRuntimeContracts
@testable import SpottyCore
@testable import SpottyGateway

/// The Demo's only playback authority. It models the ports Spotty consumes, never a Spotify
/// server, decoder or audio device. State and fault injection share one lock; delivery happens
/// after unlocking, through the production bounded fan-out and normal store intake.
final class SyntheticPlayback: @unchecked Sendable {
    enum Fault: String, Sendable { case reject, holdObservation, disconnect }
    struct Snapshot: Codable, Sendable {
        let generation: UInt64
        let revision: UInt64
        let commandCount: Int
        let rejectedCount: Int
        let activeDevice: String
        let playing: Bool
        let positionMS: Int64
        let positionSampleCount: Int
        let queuedUIDs: [String]
    }

    static let localID = "synthetic-mac"
    static let remoteID = "synthetic-speaker"
    private let lock = NSLock()
    private let fanout = EngineEventFanout(clock: SystemPlaybackClock())
    private var generation: UInt64 = 1
    private var revision: UInt64 = 0
    private var commandCount = 0
    private var rejectedCount = 0
    private var positionSampleCount = 0
    private var activeID = SyntheticPlayback.remoteID
    private var connected = true
    private var playing = false
    private var trackURI = "spotify:track:synthetic0x0"
    private var positionMS: Int64 = 0
    private var shuffle = false
    private var repeatTrack = false
    private var repeatContext = false
    private var queue: [QueueProtocolTrack] = (1...12).map {
        QueueProtocolTrack(uri: "spotify:track:synthetic0x\($0 % 6)", uid: "demo-queue-\($0)", provider: "queue")
    }
    private var nextFault: Fault?
    private var held: [RustPlaybackEvent] = []

    func events() -> AsyncStream<RustPlaybackEventEnvelope> { fanout.events() }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                generation: generation, revision: revision, commandCount: commandCount,
                rejectedCount: rejectedCount, activeDevice: activeID, playing: playing,
                positionMS: positionMS, positionSampleCount: positionSampleCount, queuedUIDs: queue.map(\.uid))
        }
    }

    func inject(_ fault: Fault) { lock.withLock { nextFault = fault } }

    @discardableResult
    func publish() -> UInt64 {
        let (event, publishedRevision) = lock.withLock { (clusterLocked(), revision) }
        fanout.emit(event)
        return publishedRevision
    }

    func handoff(to deviceID: String) {
        let event = lock.withLock {
            activeID = deviceID
            return clusterLocked()
        }
        fanout.emit(event)
    }

    func setConnected(_ value: Bool) {
        let event = lock.withLock {
            connected = value
            return clusterLocked()
        }
        fanout.emit(event)
    }

    func replaceSession(preservingPlayback: Bool = false, publish: Bool = true) {
        let event = lock.withLock {
            generation += 1
            connected = true
            if !preservingPlayback {
                playing = false
                positionMS = 0
            }
            return clusterLocked()
        }
        if publish { fanout.emit(event) }
    }

    /// Release retained old observations unchanged: their original generation/revision must be
    /// rejected by real intake when another owner or session has superseded them.
    func releaseHeldObservations(reversed: Bool = false) {
        let events = lock.withLock {
            let result = held
            held.removeAll()
            return result
        }
        for event in reversed ? events.reversed() : events { fanout.emit(event) }
    }

    func advance(milliseconds: Int64) {
        let event = lock.withLock {
            positionSampleCount += 1
            if playing { positionMS = min(180_000, positionMS + milliseconds) }
            revision += 1
            return RustPlaybackEvent.playback(playbackLocked())
        }
        fanout.emit(event)
    }

    func execute(_ operation: LocalPlaybackOperation) -> PlaybackEngineResult {
        apply {
            switch operation {
            case let .playURI(uri): trackURI = uri; playing = true; positionMS = 0
            case let .playTracks(uris):
                if let first = uris.first { trackURI = first; playing = true; positionMS = 0 }
            case .pause: playing = false
            case .resume, .rehydrate: playing = true
            case .next: skipLocked()
            case .previous: positionMS = 0
            case let .seek(value): positionMS = Int64(value)
            case let .shuffle(value): shuffle = value
            case let .repeatOptions(plan):
                for mutation in plan.mutations {
                    switch mutation.flag {
                    case .track: repeatTrack = mutation.enabled
                    case .context: repeatContext = mutation.enabled
                    }
                }
            case let .addToQueue(uri): appendLocked(uri)
            case .transferToLocal: activeID = Self.localID
            case let .transferToDevice(id): activeID = id
            }
        }
    }

    func send(_ command: SpotifyConnectCommand, to target: String) throws {
        let result = apply(target: target) {
            switch command.endpoint {
            case .pause: playing = false
            case .resume: playing = true
            case .next: skipLocked()
            case .previous: positionMS = 0
            case .seek:
                if case let .integer(value) = command.value { positionMS = Int64(value) }
            case .shuffle:
                if case let .boolean(value) = command.value { shuffle = value }
            case .repeatTrack:
                if case let .boolean(value) = command.value { repeatTrack = value }
            case .repeatContext:
                if case let .boolean(value) = command.value { repeatContext = value }
            case .addToQueue:
                if let uri = command.track?.uri { appendLocked(uri) }
            case .setQueue:
                queue = (command.nextTracks ?? []).map {
                    QueueProtocolTrack(
                        uri: $0.uri, uid: $0.uid, provider: $0.provider, metadata: $0.metadata,
                        removed: $0.removed, blocked: $0.blocked, restrictions: $0.restrictions,
                        albumURI: $0.albumURI, disallowReasons: $0.disallowReasons, artistURI: $0.artistURI)
                }
            case .play:
                if let context = command.context {
                    if let first = context.trackURIs?.first {
                        trackURI = first
                    } else if context.uri.hasPrefix("spotify:track:") {
                        trackURI = context.uri
                    } else if let playlistID = SpotifyURI.id(from: context.uri, kind: "playlist"),
                        playlistID.hasPrefix("synthetic")
                    {
                        trackURI = "spotify:track:\(playlistID)x\(max(0, context.trackIndex ?? 0))"
                    }
                    playing = true; positionMS = 0
                }
            }
        }
        if !result.isOK { throw BrowsingFailure.unsupportedAction }
    }

    private func apply(target: String? = nil, _ mutation: () -> Void) -> PlaybackEngineResult {
        let outcome: (PlaybackEngineResult, RustPlaybackEvent?) = lock.withLock {
            commandCount += 1
            let fault = nextFault
            nextFault = nil
            if fault == .reject || !connected || (target != nil && target != activeID) {
                rejectedCount += 1
                return (.error, nil)
            }
            if fault == .disconnect {
                connected = false
                return (.error, clusterLocked())
            }
            mutation()
            let event = clusterLocked()
            if fault == .holdObservation { held.append(event); return (.ok, nil) }
            return (.ok, event)
        }
        if let event = outcome.1 { fanout.emit(event) }
        return outcome.0
    }

    private func appendLocked(_ uri: String) {
        queue.append(QueueProtocolTrack(uri: uri, uid: "demo-added-\(commandCount)", provider: "queue"))
    }

    private func skipLocked() {
        if !queue.isEmpty { trackURI = queue.removeFirst().uri }
        positionMS = 0
    }

    func replaceQueueForMeasurement(wave: Int, count: Int) {
        let event = lock.withLock {
            queue = (0..<count).map {
                QueueProtocolTrack(
                    uri: "spotify:track:syntheticWave\(wave)x\($0)", uid: "wave-\(wave)-\($0)", provider: "queue")
            }
            return clusterLocked()
        }
        fanout.emit(event)
    }

    func queueSnapshot() -> RustQueueState { lock.withLock { queueLocked() } }

    private func queueLocked() -> RustQueueState {
        RustQueueState(
            revision: revision, sessionGeneration: generation,
            track: .init(uri: trackURI, provider: "context", uid: "current"),
            protocolNextTracks: queue, protocolPrevTracks: [], queueRevision: "demo-\(revision)",
            disallowSetQueue: false, disallowRemovingFromNextTracks: false)
    }

    private func playbackLocked() -> RustPlaybackState {
        RustPlaybackState(
            revision: revision, sessionGeneration: generation, isPlaying: playing,
            isPaused: !playing, trackURI: trackURI, positionMS: positionMS, durationMS: 180_000,
            timestampMS: Int64(Date().timeIntervalSince1970 * 1_000), shuffle: shuffle,
            repeatTrack: repeatTrack, repeatContext: repeatContext,
            isActiveDevice: activeID == Self.localID, contextURI: "spotify:playlist:synthetic0")
    }

    private func clusterLocked() -> RustPlaybackEvent {
        revision += 1
        return .cluster(
            RustConnectClusterState(
                revision: revision, sessionGeneration: generation, source: 2, localDeviceID: Self.localID,
                devices: RustDevicesState(
                    revision: revision, sessionGeneration: generation, activeDeviceID: activeID,
                    devices: [
                        ConnectProtocolDevice(id: Self.localID, name: "Personal MacBook", type: "computer"),
                        ConnectProtocolDevice(id: Self.remoteID, name: "Living Room", type: "speaker"),
                    ]),
                connection: RustConnectionState(
                    revision: revision, sessionGeneration: generation,
                    sessionConnected: connected, spircReady: connected, isActiveDevice: activeID == Self.localID,
                    resumePending: false, lastError: connected ? nil : "Speaker disconnected", deviceID: Self.localID),
                playback: playbackLocked(), queue: queueLocked()))
    }
}
