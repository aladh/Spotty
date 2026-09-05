//
//  PlaybackStore+EngineEvents.swift
//  Spotty
//
//  Ordered engine event intake and metadata reconciliation.
//

import SpottyDomain
import Foundation
import OSLog

extension PlaybackStore {
    /// Single ordered intake for every control callback from the embedded engine. Events from an
    /// obsolete engine generation or an older source revision are discarded before they can
    /// mutate presentation state.
    func receive(_ envelope: RustPlaybackEventEnvelope) {
        guard envelope.sequence > lastEngineEventSequence else { return }
        lastEngineEventSequence = envelope.sequence
        // Teardown must win before any ordered-source gate. Recording a revision here and then
        // bailing in `receive` would consume a snapshot the reducer never accepted.
        guard !isTearingDown else { return }

        switch envelope.event {
        case let .playback(state):
            receive(state, revision: state.revision, receivedAt: envelope.receivedAt)
        case let .queue(state):
            guard
                acceptsConnectQueueCallback(
                    generation: state.sessionGeneration,
                    revision: state.revision
                )
            else { return }
            receive(state, revision: state.revision, engineEpoch: state.sessionGeneration)
        case let .connection(state):
            receive(state, revision: state.revision, receivedAt: envelope.receivedAt)
        case let .devices(state):
            receive(
                ConnectDeviceProjection.devices(
                    from: state.devices,
                    activeDeviceID: state.activeDeviceID
                ),
                revision: state.revision,
                engineEpoch: state.sessionGeneration
            )
        }
    }

    /// MainActor dedupe for Connect queue *callbacks*. Records generation and revision together
    /// and does not adopt `engineGeneration`.
    func acceptsConnectQueueCallback(generation: UInt64?, revision: UInt64?) -> Bool {
        guard !isTearingDown else { return false }
        return connectQueueCallback.accept(
            generation: generation,
            revision: revision,
            engineEpoch: engineGeneration
        )
    }

    func receive(_ state: RustPlaybackState, revision: UInt64, receivedAt: Date) {
        guard !isTearingDown else { return }
        let isInitialSnapshot = !hasReceivedPlaybackSnapshot
        let previousTrackURI = trackURI
        // This fact belongs to the same Connect player observation as the transport and
        // identity below. Reading the store's owner here would make projection depend on
        // callback arrival order.
        let snapshotIsActiveDevice = state.isActiveDevice
        let snapshot = PlaybackSnapshotProjection.snapshot(
            isPlaying: state.isPlaying,
            isPaused: state.isPaused,
            trackURI: state.trackURI,
            positionMilliseconds: state.positionMS,
            durationMilliseconds: state.durationMS,
            timestampMilliseconds: state.timestampMS,
            shuffle: state.shuffle,
            repeatContext: state.repeatContext,
            repeatTrack: state.repeatTrack,
            trackUnavailable: state.trackUnavailable,
            isInitialSnapshot: isInitialSnapshot,
            isActiveDevice: snapshotIsActiveDevice,
            receivedAt: receivedAt,
            contextURI: state.contextURI
        )
        let accepted = send(
            .enginePlayback(snapshot),
            source: .enginePlayback,
            revision: revision,
            engineEpoch: state.sessionGeneration,
            receivedAt: receivedAt
        )
        guard accepted else { return }
        hasReceivedPlaybackSnapshot = true

        if let trackURI = snapshot.trackURI, trackURI != previousTrackURI {
            adoptTrackMetadata(for: trackURI, force: true)
        } else if snapshot.trackURI == nil {
            effects.cancel(.trackMetadata)
        }

        // A later cluster update can start Spotty remotely. Count that transition, but never turn
        // the initial account snapshot into fresh listening history merely because the app opened.
        if !isInitialSnapshot,
            snapshotIsActiveDevice,
            snapshot.transport == .playing,
            let trackURI = snapshot.trackURI,
            trackURI != previousTrackURI
        {
            recordPlayed(trackURI)
        }
    }

    func receive(
        _ state: RustQueueState,
        revision: UInt64,
        mayAdoptPlaybackIdentity: Bool = true,
        accountEpoch capturedAccountEpoch: UInt64? = nil,
        engineEpoch capturedEngineEpoch: UInt64? = nil
    ) {
        guard !isTearingDown else { return }
        let protocolNext = state.protocolNextTracks
        let protocolPrev = state.protocolPrevTracks
        let entries = QueueProtocolProjection.upcomingEntries(from: protocolNext)
        let epoch = capturedAccountEpoch ?? accountEpoch
        // Stamp from the payload generation. `engineGeneration` is only a fallback when the
        // caller omitted a captured epoch; it must not override a newer decoded epoch.
        let engineEpoch = capturedEngineEpoch ?? state.sessionGeneration
        effects.replace(
            .connectQueueAccept,
            with: Task { [weak self] in
                guard let self else { return }
                let accepted = await self.queueService.acceptConnect(
                    entries,
                    accountEpoch: epoch,
                    sourceRevision: revision,
                    contextURI: state.track?.uri ?? self.trackURI,
                    provisional: state.track == nil && entries.isEmpty,
                    engineEpoch: engineEpoch,
                    protocolNext: protocolNext,
                    protocolPrev: protocolPrev,
                    queueRevision: state.queueRevision,
                    disallowSetQueue: state.disallowSetQueue,
                    disallowRemovingFromNextTracks: state.disallowRemovingFromNextTracks
                )
                guard !Task.isCancelled, !self.isTearingDown else { return }
                guard self.accountEpoch == epoch, self.engineGeneration <= engineEpoch else { return }
                guard let accepted else { return }
                let previousOrdering = self.state.queue.entries.map(\.uri)
                self.queueMutation = accepted.mutation
                guard self.apply(accepted.snapshot, engineEpoch: engineEpoch) else { return }
                if self.state.queue.entries.map(\.uri) != previousOrdering {
                    self.queueInspectorOrderingVersion &+= 1
                }
            })

        guard let track = state.track, QueueProtocolProjection.isPlayableTrackURI(track.uri) else {
            return
        }
        if !mayAdoptPlaybackIdentity {
            guard
                queueBootstrapMetadataURI(
                    snapshotTrackURI: track.uri,
                    currentTrackURI: self.state.currentTrack?.uri
                ) != nil
            else { return }
        }

        let changedTrack = track.uri != trackURI
        if changedTrack || !hasCurrentTrackMetadata {
            // Cluster updates deliberately ship uris without names; resolve against
            // whatever the catalog already loaded so the bar never stays blank.
            if changedTrack {
                let accepted = setPresentation(
                    track: CurrentTrack(uri: track.uri),
                    timing: PlaybackTiming(anchoredAt: environment.clock.now()),
                    source: .engineQueue,
                    accountEpoch: epoch,
                    engineEpoch: engineEpoch
                )
                guard accepted else { return }
            }
            adoptTrackMetadata(
                for: track.uri,
                accountEpoch: epoch,
                engineEpoch: engineEpoch
            )
        }
    }

    /// Fills the now-playing fields for an adopted uri from what the catalog already holds.
    ///
    /// The backend ships playback-state and queue updates **without names on purpose** —
    /// resolving them was the old Web API's job. Until a resolver exists again, the loaded
    /// catalog is the source: without this, any start that bypasses a track row (grid cards,
    /// remote starts, cold context plays) plays audio into a bar that still reads
    /// "Nothing playing" and never flips its transport.
    private func adoptTrackMetadata(
        for uri: String,
        force: Bool = false,
        accountEpoch: UInt64? = nil,
        engineEpoch: UInt64? = nil
    ) {
        if !force, hasCurrentTrackMetadata { return }

        if let track = catalog.metadata.knownTrack(for: uri) {
            let accepted = setTrackMetadata(
                uri: uri,
                title: track.title,
                artist: track.artist,
                artworkURL: track.artworkURL,
                duration: track.duration > 0 ? track.duration : duration,
                provenance: .catalog,
                accountEpoch: accountEpoch,
                engineEpoch: engineEpoch
            )
            guard accepted else { return }
            effects.cancel(.trackMetadata)
            history.applyMetadata(
                uri: uri,
                title: track.title,
                artist: track.artist,
                artworkURL: track.artworkURL
            )
            return
        }

        // A URI is not metadata. Keep the transport context internally, but leave the UI in its
        // neutral state until either the queue callback or a loaded catalog supplies real names.
        let accepted = setTrackMetadata(
            uri: uri,
            title: nil,
            artist: nil,
            artworkURL: nil,
            duration: duration,
            provenance: .none,
            accountEpoch: accountEpoch,
            engineEpoch: engineEpoch
        )
        guard accepted else { return }
        resolveTrackMetadata(for: uri, accountEpoch: accountEpoch, engineEpoch: engineEpoch)
    }

    private func resolveTrackMetadata(
        for uri: String,
        accountEpoch: UInt64? = nil,
        engineEpoch: UInt64? = nil
    ) {
        let epoch = accountEpoch ?? self.accountEpoch
        let capturedEngineEpoch = engineEpoch ?? engineGeneration
        effects.replace(
            .trackMetadata,
            with: Task { [weak self] in
                do {
                    guard let self else { return }
                    let metadata = try await self.coordinator.metadata(for: uri)
                    guard !Task.isCancelled, !self.isTearingDown else { return }
                    let accepted = self.setTrackMetadata(
                        uri: uri,
                        title: metadata.title,
                        artist: metadata.artist,
                        artworkURL: metadata.artworkURL,
                        duration: metadata.duration > 0 ? metadata.duration : self.duration,
                        provenance: .connect,
                        accountEpoch: epoch,
                        engineEpoch: capturedEngineEpoch
                    )
                    guard accepted else { return }
                    self.catalog.metadata.replaceTracks(
                        [
                            CatalogTrack(
                                id: uri, uri: uri, title: metadata.title, artist: metadata.artist,
                                album: "", duration: metadata.duration, artworkURL: metadata.artworkURL,
                                addedAt: nil, artists: metadata.artists)
                        ], from: .nowPlaying)
                    self.history.applyMetadata(
                        uri: uri,
                        title: metadata.title,
                        artist: metadata.artist,
                        artworkURL: metadata.artworkURL
                    )
                } catch {
                    guard !Task.isCancelled, self?.isTearingDown == false else { return }
                    debugLog(
                        "SpotifyConnectAPI", "Track metadata resolution failed: \(String(describing: type(of: error)))")
                }
            })
    }

    func receive(_ devices: [ConnectDevice], revision: UInt64, engineEpoch: UInt64) {
        guard !isTearingDown else { return }
        let snapshot = PlaybackDeviceSnapshot(
            devices: devices.map {
                PlaybackDevice(id: $0.id, name: $0.name, type: $0.type, isActive: $0.isActive)
            },
            localDeviceID: localDeviceID,
            revision: revision,
            lastRemoteDeviceID: lastRemoteDeviceID
        )
        let accepted = send(
            .devices(snapshot),
            source: .engineDevices,
            revision: revision,
            engineEpoch: engineEpoch
        )
        guard accepted else { return }
        if let remote = devices.first(where: { $0.isActive && $0.id != localDeviceID }) {
            lastRemoteDeviceID = remote.id
            Task { await environment.preferences.setLastRemoteDeviceID(remote.id) }
        }
    }

    func receive(_ state: RustConnectionState, revision: UInt64, receivedAt: Date) {
        guard !isTearingDown else { return }
        let resolvedLocalID = ConnectionSnapshotProjection.resolvedDeviceID(
            wire: state.deviceID,
            fallback: localDeviceID
        )
        let owner = connectionPlaybackOwner(
            isLocalActive: state.isActiveDevice,
            localDeviceID: resolvedLocalID,
            localDeviceName: thisDeviceName,
            devices: self.state.devices.devices,
            currentTrackURI: self.state.currentTrack?.uri,
            previousOwner: self.state.owner,
            lastRemoteDeviceID: lastRemoteDeviceID
        )
        let session = ConnectionSnapshotProjection.sessionPhase(
            connected: state.sessionConnected,
            spircReady: state.spircReady,
            credentialsRejected: state.credentialsRejected,
            lastError: state.lastError
        )
        let accepted = send(
            .engineConnection(
                EngineConnectionSnapshot(
                    session: session,
                    owner: owner,
                    localDeviceID: resolvedLocalID
                )),
            source: .engineConnection,
            revision: revision,
            engineEpoch: state.sessionGeneration,
            receivedAt: receivedAt
        )
        guard accepted else { return }
        accountStore.receiveEngineConnection(session)
        guard !state.credentialsRejected else {
            // The snapshot was accepted for this engine/account generation. Keep the independent
            // Keymaster grant, discard only the streaming credential held by the engine, and make
            // reauthorization an explicit user action.
            accountStore.markCredentialRejection()
            engineRehydrationWindowOpen = false
            let lifetime = playbackLifetime
            effects.replace(
                .credentialRejection,
                with: Task { [weak self] in
                    guard let self,
                        self.playbackLifetime == lifetime,
                        !self.isTearingDown
                    else { return }
                    await self.endSession(
                        clearGrant: false,
                        finalPhase: .failed(ConnectionSnapshotProjection.credentialsRejectedMessage)
                    )
                }
            )
            return
        }
        engineRehydrationWindowOpen = state.resumePending && !state.spircReady
        rehydrateIfEngineIsWaiting(state)
    }

    /// Reconnect rehydration on Swift load targets.
    ///
    /// The engine publishes `resume_pending` once its rebuilt session is connected and
    /// activated, and keeps `spirc_ready` clear until a load lands or its window times out,
    /// so the session phase stays non-ready (no Web API bootstrap) while this runs. The plan
    /// comes from the same sticky engine getters as user resume; nothing is mirrored here.
    /// One sequence per engine session generation: the engine republishes the flag on every
    /// snapshot inside its window. The operation may queue behind another local command while
    /// the engine moves on, so it carries the session generation and the engine itself declines
    /// a load whose session or window is gone; the coordinator's MainActor re-check is only an
    /// early-out.
    private func rehydrateIfEngineIsWaiting(_ state: RustConnectionState) {
        guard engineRehydrationWindowOpen,
            rehydratedSessionGeneration != state.sessionGeneration
        else { return }
        rehydratedSessionGeneration = state.sessionGeneration
        let plan = resumeLoadPlan()
        let lifetime = playbackLifetime
        effects.replace(
            .reconnectRehydration,
            with: Task { [weak self] in
                guard let self, self.playbackLifetime == lifetime else { return }
                let operation = LocalPlaybackOperation.rehydrate(
                    plan, sessionGeneration: state.sessionGeneration)
                let result = await self.coordinator.performLocalIfStillWanted(operation) {
                    [weak self] in
                    guard let self else { return false }
                    return self.playbackLifetime == lifetime && self.engineRehydrationWindowOpen
                }
                if let result, !result.isOK {
                    SpottyLog.playback.debug(
                        "Reconnect rehydration did not land; result=\(result.rawValue, privacy: .public)"
                    )
                }
            })
    }

}
