//
//  PlaybackSessionRuntime+Transport.swift
//  Spotty
//
//  Transport, playback options, and Spotify Connect device actions.
//

import SpottyDomain
import SpottyRuntimeContracts
import SpottyEngineAdapter
import Foundation
import OSLog

package extension PlaybackSessionRuntime {
    func play(uri: String) {
        submitPlay(uri: uri)
    }

    func play(track: CatalogTrack) {
        submitPlay(uri: track.uri, expectedTrack: currentTrack(from: track))
    }

    func playPlaylist(_ item: CatalogItem, tracks playlistTracks: [CatalogTrack], loadedURI: String?) {
        let orderedTracks = isShuffleEnabled ? fewerRepeatsOrder(playlistTracks) : playlistTracks
        let expectedTrack: CurrentTrack?
        if loadedURI == item.uri, let first = orderedTracks.first {
            expectedTrack = currentTrack(from: first)
        } else {
            expectedTrack = nil
        }

        if isShuffleEnabled, !orderedTracks.isEmpty {
            let trackURIs = orderedTracks.map(\.uri)
            performRoutedCommand(
                "Could not shuffle that playlist",
                kind: .transport,
                expecting: true,
                expectedTiming: expectedTrack.map { playTargetTiming(from: $0) },
                expectedTrack: expectedTrack,
                local: .playTracks(trackURIs),
                remote: .play(trackURIs: trackURIs)
            )
            return
        }
        submitPlay(uri: item.uri, expectedTrack: expectedTrack)
    }

    private func submitPlay(
        uri: String,
        expectedTrack: CurrentTrack? = nil
    ) {
        let value = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return
        }
        performRoutedCommand(
            "Could not play that Spotify URI",
            expecting: true,
            expectedTiming: expectedTrack.map { playTargetTiming(from: $0) },
            expectedTrack: expectedTrack,
            local: .playURI(value),
            remote: .play(uri: value)
        )
    }

    private func currentTrack(from track: CatalogTrack) -> CurrentTrack {
        CurrentTrack(
            uri: track.uri,
            title: track.title,
            artist: track.artist,
            artworkURL: track.artworkURL,
            duration: track.duration,
            metadataSource: .catalog
        )
    }

    private func playTargetTiming(from track: CurrentTrack) -> PlaybackTiming {
        PlaybackTiming(position: 0, duration: track.duration, anchoredAt: environment.clock.now())
    }

    func toggleShuffle() {
        let enabled = !isShuffleEnabled
        // Spotify Connect only exposes an on/off command. Keep other clients in sync when
        // there is a live context; playlist starts in Spotty use the local freshness ordering.
        if isActiveDevice || activeRemoteDevice != nil {
            let preferenceWriter = self.preferenceWriter
            let epoch = accountEpoch
            performRoutedCommand(
                "Could not update shuffle",
                kind: .options,
                expectedShuffle: enabled,
                local: .shuffle(enabled),
                remote: .shuffle(enabled)
            ) { accepted in
                guard accepted else { return }
                preferenceWriter.submit(epoch: epoch) { await $0.setShuffleEnabled(enabled) }
            }
            return
        }
        setShuffleEnabled(enabled)
        preferenceWriter.submit(epoch: accountEpoch) { await $0.setShuffleEnabled(enabled) }
    }

    func togglePlayback() {
        guard canTogglePlayback else { return }
        let targetIsPlaying = !isPlaying
        let now = environment.clock.now()
        let resumePlan = resumeLoadPlan()
        // A cold idle join can retain a displayed track without any engine resume
        // identity (for example, an empty Connect context). Treat the explicit Play
        // press as a fresh track selection in that narrow case; do not fabricate a
        // sticky resume plan or change reconnect rehydration.
        let startsRetainedTrack =
            targetIsPlaying && defaultLocalPlaybackDevice != nil
            && resumePlan.targets().isEmpty && !trackURI.isEmpty
        let localOperation: LocalPlaybackOperation =
            !targetIsPlaying ? .pause : (startsRetainedTrack ? .playURI(trackURI) : .resume(resumePlan))
        let expectedTiming: PlaybackTiming
        if targetIsPlaying {
            // A paused anchor may be arbitrarily old; resume interpolation from now.
            expectedTiming = PlaybackTiming(
                position: startsRetainedTrack ? 0 : position, duration: duration, anchoredAt: now)
        } else {
            // Freeze the smooth UI clock in the same event that applies paused transport. The
            // local player can still refresh an exact position as a follow-up; a remote device
            // is represented by this clock.
            if isActiveDevice {
                refreshPosition()
            }
            expectedTiming = PlaybackTiming(
                position: displayedPosition(at: now),
                duration: duration,
                anchoredAt: now
            )
        }

        let failure = targetIsPlaying ? "Resume was rejected" : "Pause was rejected"
        performRoutedCommand(
            failure,
            kind: .transport,
            expecting: targetIsPlaying,
            expectedTiming: expectedTiming,
            local: localOperation,
            remote: targetIsPlaying ? .resume : .pause
        ) { [weak self] accepted in
            guard let self, accepted else { return }
            self.refreshPosition()
        }
    }

    func next() {
        performRoutedCommand(
            "Next was rejected",
            kind: .navigation,
            local: .next,
            remote: .next
        )
    }

    func previous() {
        performRoutedCommand(
            "Previous was rejected",
            kind: .navigation,
            local: .previous,
            remote: .previous
        )
    }

    func seek(to fraction: Double) {
        let milliseconds = UInt32(max(0, min(1, fraction)) * duration * 1_000)
        let now = environment.clock.now()
        performRoutedCommand(
            "Seek was rejected",
            kind: .seek,
            expectedTiming: PlaybackTiming(
                position: TimeInterval(milliseconds) / 1_000,
                duration: duration,
                anchoredAt: now
            ),
            local: .seek(milliseconds),
            remote: .seek(to: Int(milliseconds))
        )
    }

    func refreshPosition() {
        guard isConnected, showsPauseControl, isActiveDevice else { return }
        let lifetime = playbackLifetime
        let capturedTrackURI = state.currentTrack?.uri
        effects.run(.positionRefresh) { [weak self] in
            guard let self else { return }
            let position = await self.coordinator.positionMilliseconds()
            guard self.stillCurrent(lifetime, requiresConnection: true) else { return }
            // The engine getter is awaited independently of its playback snapshot. A track
            // transition can therefore land while it is suspended; never attribute the old
            // track's position to the newly current track. Epochs alone only protect the
            // account and engine lifetime, not the track identity.
            guard self.state.currentTrack?.uri == capturedTrackURI else { return }
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
        let nextFlags = repeatMode.next.flags
        let plan = RepeatTransitionPlan.planning(from: state.options.repeatFlags, to: nextFlags)
        performRoutedOperation(
            "Could not update repeat",
            kind: .options,
            expectedRepeatFlags: nextFlags,
            local: .repeatOptions(plan),
            remote: { api, from, to in
                try await RepeatTransitionApplication.applyRemote(plan) { mutation in
                    try await api.send(.repeatMutation(mutation), from: from, to: to)
                }
            }
        )
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
        if device.id == localDeviceID {
            performCommand(
                "Could not move playback to this Mac",
                operation: .transferToLocal,
                kind: .transfer,
                completion: announceSuccess
            )
            return
        }
        performCommand(
            "Could not move playback to \(device.name)",
            expectedOwner: .uncertain(
                PlaybackDevice(
                    id: device.id,
                    name: device.name,
                    type: device.type,
                    isActive: false
                )),
            operation: .transferToDevice(device.id),
            kind: .transfer,
            completion: announceSuccess
        )
    }

    /// Sticky resume-load identity read through the engine getters, never presentation state.
    /// Shared by user resume and reconnect rehydration.
    func resumeLoadPlan() -> ResumeLoadPlan {
        ResumeLoadPlan.capture(
            savedAtDeactivation: environment.local.resumePositionMilliseconds(),
            live: environment.local.positionMilliseconds(),
            contextURI: environment.local.resumeContextURI(),
            trackURI: environment.local.resumeTrackURI()
        )
    }

}
