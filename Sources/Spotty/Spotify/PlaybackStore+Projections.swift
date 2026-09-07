//
//  PlaybackStore+Projections.swift
//  Spotty
//
//  Read-only presentation projections over the reducer-owned snapshot.
//

import SpottyDomain
import Foundation

extension PlaybackStore {
    var phase: Phase { state.session }
    var trackURI: String { state.currentTrack?.uri ?? "" }
    var trackTitle: String { state.currentTrack?.title ?? "Nothing playing" }
    var artistName: String { state.currentTrack?.artist ?? "Choose something to play" }
    var artworkURL: URL? { state.currentTrack?.artworkURL }
    var isPlaying: Bool { state.transport == .playing }
    var isShuffleEnabled: Bool { state.options.shuffle }
    var repeatMode: RepeatMode { state.options.repeatMode }
    var isActiveDevice: Bool {
        if case .local = state.owner { return true }
        return false
    }
    var position: TimeInterval { state.timing.position }
    var duration: TimeInterval { state.timing.duration }
    var positionAnchorDate: Date { state.timing.anchoredAt }
    var queueNextEntries: [QueueEntry] {
        state.queue.entries.map {
            QueueEntry(uri: $0.uri, provider: $0.provider, occurrence: $0.occurrence, uid: $0.uid)
        }
    }
    var connectDevices: [ConnectDevice] {
        state.devices.devices.map {
            ConnectDevice(id: $0.id, name: $0.name, type: $0.type, isActive: $0.isActive)
        }
    }
    var localDeviceID: String? { state.devices.localDeviceID }
    var defaultLocalPlaybackDevice: ConnectDevice? {
        guard canStartPlayback else { return nil }
        return ConnectDeviceProjection.defaultLocalDevice(in: state).map {
            ConnectDevice(id: $0.id, name: $0.name, type: $0.type, isActive: false)
        }
    }
    var isPlaybackCommandPending: Bool { catalogPlaybackAvailability.hasPendingPlaybackCommand }
    var hasCurrentTrackMetadata: Bool { (state.currentTrack?.metadataSource ?? .none) != .none }
    var playbackNotice: PlaybackNotice? { state.notice }
    var transientCommandError: String? { state.notice?.message }
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
        isConnected && !isTearingDown && terminationGate.allowsCommands && !isPlaybackCommandPending
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
        switch state.owner {
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
            owner: state.owner,
            hasCurrentTrack: hasCurrentTrack,
            isPlaying: isPlaying
        )
    }

    var commandRoute: ConnectCommandRoute {
        connectCommandRoute(owner: state.owner, localDeviceID: localDeviceID)
    }
}

struct RemotePlaybackBannerPresentation: Equatable {
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
