//
//  PlaybackSessionRuntime+Projections.swift
//  Spotty
//
//  Runtime command projections and the semantic snapshot published to clients.
//

import SpottyDomain
import SpottyRuntimeContracts
import Foundation

package extension PlaybackSessionRuntime {
    var phase: Phase { semantic.session }
    var trackURI: String { semantic.currentTrack?.uri ?? "" }
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
    var localDeviceID: String? { presentedLocalDeviceID }
    var defaultLocalPlaybackDevice: ConnectDevice? {
        guard canStartPlayback else { return nil }
        return ConnectDeviceProjection.defaultLocalDevice(in: state).map {
            ConnectDevice(id: $0.id, name: $0.name, type: $0.type, isActive: false)
        }
    }
    var isPlaybackCommandPending: Bool { catalogPlaybackAvailability.hasPendingPlaybackCommand }
    var hasCurrentTrackMetadata: Bool { (semantic.currentTrack?.metadataSource ?? .none) != .none }
    var isConnected: Bool { catalogPlaybackAvailability.isConnected }
    var catalogCurrentTrack: CatalogTrack? {
        guard !trackURI.isEmpty else { return nil }
        return catalog.metadata.knownTrack(for: trackURI)
    }
    var hasCurrentTrack: Bool {
        !trackURI.isEmpty && (hasCurrentTrackMetadata || catalogCurrentTrack != nil)
    }
    /// Connect is account-wide: another device playing is still live playback Spotty can control.
    var showsPauseControl: Bool { hasCurrentTrack && isPlaying }
    var canStartPlayback: Bool {
        isConnected && !isTearingDown && terminationGate.allowsCommands && !isPlaybackCommandPending
    }
    var canTogglePlayback: Bool {
        canStartPlayback && hasCurrentTrack && (isPlaying || semantic.blockedResumeTarget == nil)
    }

    func displayedPosition(at date: Date) -> TimeInterval {
        SpottyDomain.interpolatedPlaybackPosition(
            anchor: position,
            anchoredAt: positionAnchorDate,
            now: date,
            isPlaying: showsPauseControl,
            duration: duration
        )
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

    var commandRoute: ConnectCommandRoute {
        connectCommandRoute(owner: semantic.owner, localDeviceID: localDeviceID)
    }
}

/// Display facts without source watermarks, pending-operation bookkeeping or timing samples.
package struct PlaybackSemanticProjection: Equatable, Sendable {
    package let accountEpoch: UInt64
    package let engineEpoch: UInt64
    package let session: PlaybackSessionPhase
    package let owner: PlaybackOwner
    package let transport: PlaybackTransportState
    package let currentTrack: CurrentTrack?
    package let playbackContextURI: String?
    package let options: PlaybackOptions
    package let notice: PlaybackNotice?
    package let blockedResumeTarget: PlaybackResumeTarget?
    package let pendingSeekID: UUID?

    package init(state: PlaybackState) {
        accountEpoch = state.accountEpoch
        engineEpoch = state.engineEpoch
        session = state.session
        owner = state.owner
        transport = state.transport
        currentTrack = state.currentTrack
        playbackContextURI = state.playbackContextURI
        options = state.options
        notice = state.notice
        blockedResumeTarget = state.blockedResumeTarget
        pendingSeekID = state.pendingCommands[.seek]?.id
    }
}
