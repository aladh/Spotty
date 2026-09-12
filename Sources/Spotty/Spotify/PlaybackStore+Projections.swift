//
//  PlaybackStore+Projections.swift
//  Spotty
//
//  Read-only presentation projections over the reducer-owned snapshot.
//

import SpottyDomain
import SpottyRuntimeContracts
import Foundation

extension PlaybackStore {
    var phase: Phase { semantic.session }
    var trackURI: String { semantic.currentTrack?.uri ?? "" }
    var trackTitle: String { semantic.currentTrack?.title ?? "Nothing playing" }
    var artistName: String { semantic.currentTrack?.artist ?? "Choose something to play" }
    var artworkURL: URL? { semantic.currentTrack?.artworkURL }
    var isPlaying: Bool { semantic.transport == .playing }
    var isShuffleEnabled: Bool { semantic.options.shuffle }
    var repeatMode: RepeatMode { semantic.options.repeatMode }
    var isActiveDevice: Bool {
        if case .local = semantic.owner { return true }
        return false
    }
    var position: TimeInterval { timeline.position }
    var duration: TimeInterval { playbackDuration }
    var positionAnchorDate: Date { timeline.anchoredAt }
    var queueNextEntries: [QueueEntry] { presentedQueueEntries }
    var connectDevices: [ConnectDevice] { presentedDevices }
    var localDeviceID: String? { presentedLocalDeviceID }
    var defaultLocalPlaybackDevice: ConnectDevice? {
        guard canStartPlayback else { return nil }
        _ = semantic
        _ = presentedDevices
        _ = presentedLocalDeviceID
        return ConnectDeviceProjection.defaultLocalDevice(in: state).map {
            ConnectDevice(id: $0.id, name: $0.name, type: $0.type, isActive: false)
        }
    }
    var isPlaybackCommandPending: Bool { catalogPlaybackAvailability.hasPendingPlaybackCommand }
    var hasCurrentTrackMetadata: Bool { (semantic.currentTrack?.metadataSource ?? .none) != .none }
    var playbackNotice: PlaybackNotice? { semantic.notice }
    var transientCommandError: String? { semantic.notice?.message }
    var isConnected: Bool { catalogPlaybackAvailability.isConnected }
    var catalogCurrentTrack: CatalogTrack? {
        guard !trackURI.isEmpty else { return nil }
        return catalog.metadata.knownTrack(for: trackURI)
    }
    var displayedTrackTitle: String { catalogCurrentTrack?.title ?? trackTitle }
    var displayedArtistName: String { catalogCurrentTrack?.artist ?? artistName }
    var displayedArtworkURL: URL? { catalogCurrentTrack?.artworkURL ?? artworkURL }
    var hasCurrentTrack: Bool {
        !trackURI.isEmpty && (hasCurrentTrackMetadata || catalogCurrentTrack != nil)
    }
    /// Connect is account-wide: another device playing is still live playback Spotty can control.
    var showsPauseControl: Bool { hasCurrentTrack && isPlaying }
    var canStartPlayback: Bool {
        isConnected && !isTearingDown && allowsCommands && !isPlaybackCommandPending
    }
    var canTogglePlayback: Bool { canStartPlayback && hasCurrentTrack }
    var canSkipTrack: Bool { canStartPlayback && hasCurrentTrack }

    func displayedPosition(at date: Date) -> TimeInterval {
        SpottyDomain.interpolatedPlaybackPosition(
            anchor: position,
            anchoredAt: positionAnchorDate,
            now: date,
            isPlaying: showsPauseControl,
            duration: duration
        )
    }

    var statusText: String {
        switch phase {
        case .signedOut: "Connect Spotify Premium"
        case .authorizing: "Waiting for Spotify…"
        case .connecting: "Starting Spotty Connect…"
        case .recovering: "Restoring Spotify Connect…"
        case .ready:
            if let transientCommandError {
                transientCommandError
            } else if let remote = activeRemoteDevice {
                isPlaying ? "Playing on \(remote.name)" : "Paused on \(remote.name)"
            } else if showsPauseControl {
                "Playing on this Mac"
            } else {
                "Spotty Connect is ready"
            }
        case let .failed(message): message
        }
    }

    var activeRemoteDevice: ConnectDevice? {
        guard !isActiveDevice, hasCurrentTrack else { return nil }
        let device: PlaybackDevice?
        switch semantic.owner {
        case let .remote(value), let .uncertain(.some(value)):
            device = value
        default:
            device = nil
        }
        if let device {
            return ConnectDevice(
                id: device.id,
                name: device.name,
                type: device.type,
                isActive: device.isActive
            )
        }
        return nil
    }

    var remotePlaybackBanner: RemotePlaybackBannerPresentation? {
        remotePlaybackBannerPresentation(
            phase: phase,
            owner: semantic.owner,
            hasCurrentTrack: hasCurrentTrack,
            isPlaying: isPlaying
        )
    }

    var commandRoute: ConnectCommandRoute {
        connectCommandRoute(owner: semantic.owner, localDeviceID: localDeviceID)
    }
}

struct RemotePlaybackBannerPresentation: Equatable, Sendable {
    let device: ConnectDevice
    let isPlaying: Bool
}

func remotePlaybackBannerPresentation(
    phase: PlaybackSessionPhase,
    owner: PlaybackOwner,
    hasCurrentTrack: Bool,
    isPlaying: Bool
) -> RemotePlaybackBannerPresentation? {
    guard phase == .ready, hasCurrentTrack, case let .remote(device) = owner else { return nil }
    return RemotePlaybackBannerPresentation(
        device: ConnectDevice(
            id: device.id,
            name: device.name,
            type: device.type,
            isActive: device.isActive
        ),
        isPlaying: isPlaying
    )
}

/// Display facts without source watermarks, pending-operation bookkeeping or timing samples.
struct PlaybackSemanticProjection: Equatable, Sendable {
    let accountEpoch: UInt64
    let engineEpoch: UInt64
    let session: PlaybackSessionPhase
    let owner: PlaybackOwner
    let transport: PlaybackTransportState
    let currentTrack: CurrentTrack?
    let playbackContextURI: String?
    let options: PlaybackOptions
    let notice: PlaybackNotice?
    let pendingSeekID: UUID?

    init(state: PlaybackState) {
        accountEpoch = state.accountEpoch
        engineEpoch = state.engineEpoch
        session = state.session
        owner = state.owner
        transport = state.transport
        currentTrack = state.currentTrack
        playbackContextURI = state.playbackContextURI
        options = state.options
        notice = state.notice
        pendingSeekID = state.pendingCommands[.seek]?.id
    }
}
