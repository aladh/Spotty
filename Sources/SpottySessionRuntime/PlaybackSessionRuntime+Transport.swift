//
//  PlaybackSessionRuntime+Transport.swift
//  Spotty
//
//  Transport, playback options, and Spotify Connect device actions.
//

import SpottyDomain
import SpottyRuntimeContracts
import Foundation

package extension PlaybackSessionRuntime {
    func play(uri: String) {
        submitCommand(.playURI(uri), failureMessage: "Could not play that Spotify URI")
    }

    func play(track: CatalogTrack) {
        submitCommand(.playTrack(track), failureMessage: "Could not play that Spotify URI")
    }

    func activateTrack(_ track: CatalogTrack, isPlayable: Bool = true) {
        guard canStartPlayback else { return }
        // Choose against runtime authority: the desktop may still display the preceding track.
        if trackURI == track.uri && canTogglePlayback {
            guard isPlayable || isPlaying else { return }
            togglePlayback()
        } else {
            guard isPlayable else { return }
            play(track: track)
        }
    }

    func activateItem(_ item: CatalogItem, contents: CatalogPlaylistContents?) {
        guard canStartPlayback else { return }
        // A retained control must target its own selection, even before the desktop catches up.
        let isCurrent = item.kind == .track ? trackURI == item.uri : playingContextURI == item.uri
        if isCurrent && canTogglePlayback {
            togglePlayback()
        } else if item.kind == .playlist {
            playPlaylist(item, contents: contents)
        } else {
            play(uri: item.uri)
        }
    }

    func playPlaylist(_ item: CatalogItem, contents: CatalogPlaylistContents?) {
        // Home/sidebar actions may target a different playlist from the retained detail page.
        let tracks = contents?.tracks(for: item.uri, accountEpoch: accountEpoch) ?? []
        let orderedTracks = isShuffleEnabled ? fewerRepeatsOrder(tracks) : tracks
        if isShuffleEnabled, !orderedTracks.isEmpty {
            submitCommand(.playTracks(orderedTracks), failureMessage: "Could not shuffle that playlist")
        } else {
            submitCommand(
                .playContext(uri: item.uri, firstTrack: orderedTracks.first),
                failureMessage: "Could not play that Spotify URI")
        }
    }

    func toggleShuffle() {
        let enabled = !isShuffleEnabled
        // Spotify Connect only exposes an on/off command. Keep other clients in sync when
        // there is a live context; playlist starts in Spotty use the local freshness ordering.
        if isActiveDevice || activeRemoteDevice != nil {
            let preferenceState = self.preferenceState
            let epoch = accountEpoch
            submitCommand(
                .shuffle(enabled), failureMessage: "Could not update shuffle",
                completion: { accepted in
                    guard accepted else { return }
                    preferenceState.persistShuffle(enabled, accountEpoch: epoch)
                })
            return
        }
        setShuffleEnabled(enabled)
        preferenceState.persistShuffle(enabled, accountEpoch: accountEpoch)
    }

    func togglePlayback() {
        guard canTogglePlayback else { return }
        let targetIsPlaying = !isPlaying
        submitCommand(
            targetIsPlaying ? .resume : .pause,
            failureMessage: targetIsPlaying ? "Resume was rejected" : "Pause was rejected",
            completion: { [weak self] accepted in
                guard let self, accepted else { return }
                self.refreshPosition()
            })
    }

    func next() {
        submitCommand(.next, failureMessage: "Next was rejected")
    }

    func previous() {
        submitCommand(.previous, failureMessage: "Previous was rejected")
    }

    func seek(to fraction: Double) {
        guard fraction.isFinite, duration.isFinite, duration > 0 else { return }
        // Catalog/remote durations are not bounded by the engine's UInt32 millisecond ABI.
        // Clamp before conversion, including when multiplying a finite duration overflows.
        let milliseconds = UInt32(min(Double(UInt32.max), max(0, min(1, fraction)) * duration * 1_000))
        submitCommand(.seek(milliseconds: milliseconds), failureMessage: "Seek was rejected")
    }

    func refreshPosition() {
        guard isConnected, showsPauseControl, isActiveDevice else { return }
        let lifetime = playbackLifetime
        let capturedTrackURI = state.currentTrack?.uri
        effects.run(.positionRefresh) { [weak self] in
            guard let self else { return }
            let position = await self.coordinator.positionMilliseconds()
            guard self.stillCurrent(lifetime, requiresConnection: true) else { return }
            // The getter can finish after a track transition or Connect transfer, including
            // one that keeps the same track. Its local sample belongs only to local playback
            // of the captured track; account and engine epochs do not protect those facts.
            guard self.isActiveDevice, self.state.currentTrack?.uri == capturedTrackURI else { return }
            _ = self.setTiming(
                position: TimeInterval(position) / 1_000,
                accountEpoch: lifetime.accountEpoch,
                engineEpoch: lifetime.engineGeneration
            )
        }
    }

    // MARK: - Repeat

    /// Cycles off → repeat queue → repeat track → off, like Spotify's transport.
    func cycleRepeat() {
        guard canStartPlayback else { return }
        submitCommand(.repeatMode(repeatMode.next), failureMessage: "Could not update repeat")
    }

    // MARK: - Spotify Connect devices

    /// Hands playback to another Connect device. Selecting this Mac transfers back here.
    func transferPlayback(to device: ConnectDevice) {
        guard canStartPlayback else { return }
        guard device.isActive == false, device.id != activeRemoteDevice?.id else { return }
        let successTargetName = device.id == localDeviceID ? "This Mac" : device.name
        let announceSuccess: @SessionRuntimeActor (Bool) -> Void = { [weak self] accepted in
            if accepted {
                self?.feedback.success("Playback request sent to \(successTargetName)")
            }
        }
        submitCommand(
            .transfer(device),
            failureMessage: device.id == localDeviceID
                ? "Could not move playback to this Mac" : "Could not move playback to \(device.name)",
            completion: announceSuccess)
    }

    /// Sticky resume-load identity read through the engine getters, never presentation state.
    /// Used only for reconnect rehydration; user resume validates an observed target.
    func resumeLoadPlan() -> ResumeLoadPlan {
        ResumeLoadPlan.capture(
            savedAtDeactivation: environment.local.resumePositionMilliseconds(),
            live: environment.local.positionMilliseconds(),
            contextURI: environment.local.resumeContextURI(),
            trackURI: environment.local.resumeTrackURI()
        )
    }

}
