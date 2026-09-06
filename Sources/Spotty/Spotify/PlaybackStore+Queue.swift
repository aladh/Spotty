//
//  PlaybackStore+Queue.swift
//  Spotty
//
//  Queue commands, refresh, and provenance-aware presentation.
//

import SpottyDomain
import Foundation
import OSLog

extension PlaybackStore {
    // MARK: - Queue panel

    /// Appends tracks to the play queue, as the official client's context menu does.
    ///
    /// Deliberately not routed through `performCommand`: queue adds are independent of
    /// transport state, and serializing them behind the pending flag would silently
    /// drop a second quick add. Multiple URIs are sent in visible order as sequential
    /// `add_to_queue` commands; presentation is not edited locally.
    func addToQueue(uris: [String]) {
        let ordered = uris.filter { !$0.isEmpty }
        guard !ordered.isEmpty else { return }
        guard canStartPlayback else {
            feedback.failure("Connect Spotify before adding to the queue.")
            return
        }

        switch commandRoute {
        case .waitingForLocalIdentity:
            feedback.failure("Spotty is still joining Spotify Connect.")
            return
        case .needsDeviceSelection:
            feedback.failure(QueueMutationRefusal.needsDeviceSelection.feedbackMessage)
            return
        case let .remote(from, to):
            let effectID = PlaybackEffectID.queueCommand(UUID())
            let epoch = accountEpoch
            effects.replace(
                effectID,
                with: Task { [weak self] in
                    defer { self?.effects.complete(effectID) }
                    guard let self else { return }
                    var completed = 0
                    for uri in ordered {
                        do {
                            try await self.coordinator.performRemote(.addToQueue(uri), from: from, to: to)
                            completed += 1
                        } catch {
                            guard !Task.isCancelled, self.accountEpoch == epoch, self.isConnected else { return }
                            self.presentAddToQueueFeedback(requested: ordered.count, completed: completed)
                            return
                        }
                    }
                    guard !Task.isCancelled, self.accountEpoch == epoch, self.isConnected else { return }
                    self.presentAddToQueueFeedback(requested: ordered.count, completed: completed)
                })
            return
        case .local:
            break
        }

        let effectID = PlaybackEffectID.queueCommand(UUID())
        let epoch = accountEpoch
        effects.replace(
            effectID,
            with: Task { [weak self] in
                defer { self?.effects.complete(effectID) }
                guard let self else { return }
                var completed = 0
                for uri in ordered {
                    let result = await self.coordinator.performLocal(.addToQueue(uri))
                    guard result.isOK else {
                        guard !Task.isCancelled, self.accountEpoch == epoch, self.isConnected else { return }
                        self.presentAddToQueueFeedback(requested: ordered.count, completed: completed)
                        return
                    }
                    completed += 1
                }
                guard !Task.isCancelled, self.accountEpoch == epoch, self.isConnected else { return }
                self.presentAddToQueueFeedback(requested: ordered.count, completed: completed)
            })
    }

    func removeUpcomingQueueOccurrences(selectedIDs: Set<String>) {
        guard queueReplacementToken == nil, !isTearingDown else { return }
        let presentationEntries = queueNextEntries
        switch queueRemoval(selectedIDs: selectedIDs, visibleUpcoming: presentationEntries) {
        case let .failure(reason):
            if reason == .nothingSelected { return }
            feedback.failure(reason.feedbackMessage)
            return
        case let .success(replacement):
            switch commandRoute {
            case .waitingForLocalIdentity:
                feedback.failure(QueueMutationRefusal.joiningConnect.feedbackMessage)
                return
            case .needsDeviceSelection:
                feedback.failure(QueueMutationRefusal.needsDeviceSelection.feedbackMessage)
                return
            case .local:
                feedback.failure(QueueMutationRefusal.localOwnerUnsupported.feedbackMessage)
                return
            case let .remote(from, to):
                let epoch = accountEpoch
                let engineEpoch = engineGeneration
                let beforeEntries = presentationEntries
                let token = UUID()
                queueReplacementToken = token
                effects.replace(
                    .queueReplacement,
                    with: Task { [weak self] in
                        defer { self?.finishQueueReplacementIfCurrent(token) }
                        do {
                            guard let self else { return }
                            try await self.coordinator.performRemote(
                                .setQueue(
                                    next: replacement.next,
                                    prev: replacement.prev,
                                    queueRevision: replacement.queueRevision
                                ),
                                from: from,
                                to: to
                            )
                            guard
                                self.queueReplacementStillCurrent(
                                    token: token,
                                    accountEpoch: epoch,
                                    engineEpoch: engineEpoch,
                                    from: from,
                                    to: to
                                )
                            else { return }
                            let mutation = await self.queueService.recordCommittedReplacement(
                                replacement,
                                accountEpoch: epoch,
                                engineEpoch: engineEpoch
                            )
                            guard
                                self.queueReplacementStillCurrent(
                                    token: token,
                                    accountEpoch: epoch,
                                    engineEpoch: engineEpoch,
                                    from: from,
                                    to: to
                                )
                            else { return }
                            if let mutation {
                                self.queueMutation = mutation
                            }
                            self.feedback.success(Self.removedFromQueueMessage(count: replacement.removedCount))
                        } catch {
                            guard let self,
                                self.queueReplacementStillCurrent(
                                    token: token,
                                    accountEpoch: epoch,
                                    engineEpoch: engineEpoch,
                                    from: from,
                                    to: to
                                )
                            else { return }
                            guard self.queueNextEntries == beforeEntries else { return }
                            self.feedback.failure("Spotify couldn’t update the queue.")
                        }
                    })
            }
        }
    }

    func queueRemoval(
        selectedIDs: Set<String>,
        visibleUpcoming: [QueueEntry]
    ) -> Result<QueueReplacement, QueueMutationRefusal> {
        QueueMutationPolicy.evaluateRemoval(
            selectedIDs: selectedIDs,
            visibleUpcoming: visibleUpcoming,
            nowPlayingID: "now-playing",
            historyIDs: Set(history.entries.map(\.id)),
            mutation: queueMutation,
            route: commandRoute,
            isConnected: isConnected && !isTearingDown,
            accountEpoch: accountEpoch,
            engineEpoch: engineGeneration
        )
    }

    func canRemoveUpcomingQueue(selectedIDs: Set<String>) -> Bool {
        guard queueReplacementToken == nil, !isTearingDown else { return false }
        if case .success = queueRemoval(selectedIDs: selectedIDs, visibleUpcoming: queueNextEntries) {
            return true
        }
        return false
    }

    private func queueReplacementStillCurrent(
        token: UUID,
        accountEpoch: UInt64,
        engineEpoch: UInt64,
        from: String,
        to: String
    ) -> Bool {
        guard !Task.isCancelled, !isTearingDown else { return false }
        guard queueReplacementToken == token else { return false }
        guard self.accountEpoch == accountEpoch, self.engineGeneration == engineEpoch else { return false }
        guard isConnected else { return false }
        guard case let .remote(currentFrom, currentTo) = commandRoute,
            currentFrom == from, currentTo == to
        else { return false }
        return true
    }

    private func finishQueueReplacementIfCurrent(_ token: UUID) {
        guard queueReplacementToken == token else { return }
        queueReplacementToken = nil
        effects.complete(.queueReplacement)
    }

    private func presentAddToQueueFeedback(requested: Int, completed: Int) {
        guard let report = QueueAddFeedbackPolicy.evaluate(requested: requested, completed: completed) else {
            return
        }
        switch report.kind {
        case .success:
            feedback.success(report.message)
        case .informational:
            feedback.informational(report.message)
        case .failure:
            feedback.failure(report.message)
        }
    }

    private static func removedFromQueueMessage(count: Int) -> String {
        count == 1 ? "Removed from Queue" : "Removed \(count) songs from Queue"
    }

    /// Pulls the backend's last-known queue so the panel opens with content even
    /// before the next cluster update streams in.
    func refreshQueueSnapshot() {
        let epoch = accountEpoch
        effects.replace(
            .queueSnapshot,
            with: Task { [weak self] in
                guard let self,
                    let state = await self.coordinator.queueSnapshot(),
                    !Task.isCancelled,
                    !self.isTearingDown,
                    self.isConnected,
                    self.accountEpoch == epoch
                else { return }
                guard
                    self.acceptsConnectQueueCallback(
                        generation: state.sessionGeneration,
                        revision: state.revision
                    )
                else { return }
                self.receive(
                    state,
                    revision: state.revision,
                    mayAdoptPlaybackIdentity: false,
                    accountEpoch: epoch,
                    engineEpoch: state.sessionGeneration
                )
            })
    }

    /// Refreshes the cross-device queue without changing playback.
    ///
    /// The documented Web API response is preferred because it carries both exact ordering and
    /// metadata. Spotify currently rate-limits its desktop client grant at api.spotify.com, so a
    /// failed attempt falls back to the already-synchronized Connect queue and hydrates its uris
    /// through spclient in small batches.
    func refreshQueue() {
        guard isConnected else { return }
        refreshQueueSnapshot()
        catalog.metadata.retainTracks(from: .queue, for: Set(queueNextEntries.map(\.uri) + [trackURI]))
        let cachedTracks = queueNextEntries.compactMap { catalog.metadata.knownTrack(for: $0.uri) }
        let epoch = accountEpoch
        let capturedEngineEpoch = engineGeneration
        effects.replace(
            .queueRefresh,
            with: Task { [weak self] in
                guard let self else { return }
                guard
                    let snapshot = await self.queueService.refresh(
                        fallbackEntries: self.queueNextEntries,
                        cachedTracks: cachedTracks,
                        currentTrackURI: self.trackURI.isEmpty ? nil : self.trackURI,
                        accountEpoch: epoch,
                        onUpdate: { [weak self] update in
                            guard let self, !Task.isCancelled,
                                !self.isTearingDown, self.isConnected
                            else { return }
                            self.apply(update, engineEpoch: capturedEngineEpoch)
                        }
                    ), !Task.isCancelled, !self.isTearingDown, self.isConnected
                else { return }
                self.apply(snapshot, engineEpoch: capturedEngineEpoch)
            })
    }

    func cancelQueueRefresh() {
        effects.cancel(.queueRefresh)
        effects.cancel(.queueSnapshot)
    }

    @discardableResult
    func apply(_ snapshot: ProvenanceQueueSnapshot, engineEpoch: UInt64) -> Bool {
        let accepted = send(
            .queue(
                PlaybackQueueSnapshot(
                    entries: snapshot.entries.map {
                        PlaybackQueueItem($0)
                    },
                    source: snapshot.source,
                    completeness: snapshot.completeness,
                    revision: snapshot.revision,
                    receivedAt: snapshot.receivedAt,
                    contextURI: snapshot.contextURI
                )),
            source: .engineQueue,
            revision: snapshot.revision,
            engineEpoch: engineEpoch,
            accountEpoch: snapshot.accountEpoch,
            receivedAt: snapshot.receivedAt
        )
        guard accepted else { return false }
        var retainedURIs = Set(snapshot.entries.map(\.uri))
        if let contextURI = snapshot.contextURI { retainedURIs.insert(contextURI) }
        catalog.metadata.retainTracks(from: .queue, for: retainedURIs)
        catalog.metadata.replaceTracks(snapshot.tracks, from: .queue)
        return true
    }

}
