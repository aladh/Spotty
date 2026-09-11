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
            let lifetime = playbackLifetime
            let route = ConnectCommandRoute.remote(from: from, to: to)
            effects.run(effectID) { [weak self] in
                guard let self else { return }
                var completed = 0
                for uri in ordered {
                    guard
                        let intentID = self.startQueueIntent(
                            adding: uri, timeoutEffect: effectID, lifetime: lifetime,
                            remainingRequests: ordered.count - completed - 1)
                    else { return }
                    do {
                        guard
                            let permit = self.makePlaybackDispatchPermit(
                                intentID: intentID,
                                ifStillWanted: {
                                    self.stillCurrent(lifetime, requiresConnection: true, route: route)
                                })
                        else { return }
                        guard
                            let outcome = try await self.coordinator.performRemoteCommand(
                                { client in
                                    try await client.send(.addToQueue(uri), from: from, to: to)
                                },
                                permit: permit
                            )
                        else { return }
                        guard
                            let accepted = self.finishQueueIntent(
                                intentID, outcome: outcome, lifetime: lifetime)
                        else { return }
                        guard accepted else {
                            guard self.stillCurrent(lifetime, requiresConnection: true, route: route) else { return }
                            self.presentAddToQueueFeedback(requested: ordered.count, completed: completed)
                            return
                        }
                        completed += 1
                    } catch {
                        guard self.stillCurrent(lifetime, requiresConnection: true, route: route) else { return }
                        self.presentAddToQueueFeedback(requested: ordered.count, completed: completed)
                        return
                    }
                }
                guard self.stillCurrent(lifetime, requiresConnection: true, route: route) else { return }
                self.presentAddToQueueFeedback(requested: ordered.count, completed: completed)
            }
            return
        case .local:
            break
        }

        let effectID = PlaybackEffectID.queueCommand(UUID())
        let lifetime = playbackLifetime
        let route = ConnectCommandRoute.local
        effects.run(effectID) { [weak self] in
            guard let self else { return }
            var completed = 0
            for uri in ordered {
                guard
                    let intentID = self.startQueueIntent(
                        adding: uri, timeoutEffect: effectID, lifetime: lifetime,
                        remainingRequests: ordered.count - completed - 1)
                else { return }
                guard
                    let permit = self.makePlaybackDispatchPermit(
                        intentID: intentID,
                        ifStillWanted: {
                            self.stillCurrent(lifetime, requiresConnection: true, route: route)
                        })
                else { return }
                do {
                    guard
                        let outcome = try await self.coordinator.performLocalCommand(
                            .addToQueue(uri),
                            permit: permit
                        )
                    else { return }
                    guard
                        let accepted = self.finishQueueIntent(
                            intentID, outcome: outcome, lifetime: lifetime)
                    else { return }
                    guard accepted else {
                        guard self.stillCurrent(lifetime, requiresConnection: true, route: route) else { return }
                        self.presentAddToQueueFeedback(requested: ordered.count, completed: completed)
                        return
                    }
                } catch {
                    guard self.stillCurrent(lifetime, requiresConnection: true, route: route) else { return }
                    self.presentAddToQueueFeedback(requested: ordered.count, completed: completed)
                    return
                }
                completed += 1
            }
            guard self.stillCurrent(lifetime, requiresConnection: true, route: route) else { return }
            self.presentAddToQueueFeedback(requested: ordered.count, completed: completed)
        }
    }

    private func startQueueIntent(
        adding uri: String? = nil, removing uids: Set<String>? = nil,
        timeoutEffect: PlaybackEffectID, lifetime: PlaybackLifetime,
        remainingRequests: Int = 0
    ) -> UUID? {
        guard stillCurrent(lifetime) else { return nil }
        let id = UUID()
        let now = environment.clock.now()
        var intent = PlaybackIntent(
            command: PendingPlaybackCommand(
                id: id, kind: .queue, expectedTransport: nil, startedAt: now), baselineTrackURI: state.currentTrack?.uri
        )
        intent.baselineOwner = state.owner
        intent.queueContextURI = state.queue.contextURI
        intent.queueRevision = state.queue.revision
        intent.removedQueueUIDs = uids
        if let uri {
            let baseline = state.queue.entries.filter { $0.uri == uri }.count
            let reserved =
                state.intents.filter { !$0.outcome.isTerminal }
                .compactMap { $0.queueMinimumCounts?[uri] }.max() ?? 0
            // Keep an overlapping reservation even if its predecessor later reports failure:
            // transport failure does not prove Spotify did not append. Rebasing could let that
            // predecessor's lone occurrence falsely confirm this distinct request.
            intent.queueMinimumCounts = [uri: max(baseline, reserved) + 1]
        }
        send(.queueIntentStarted(intent), source: .command, playbackLifetime: lifetime)
        let deadlineID = PlaybackEffectID.commandDeadline(id)
        effects.run(deadlineID) { [weak self] in
            guard let self else { return }
            do { try await self.environment.clock.sleep(seconds: 8) } catch { return }
            guard self.stillCurrent(lifetime) else { return }
            if self.state.intents.first(where: { $0.command.id == id })?.outcome.isTerminal == true {
                // Observation already settled the request, but an unreturned transport must
                // not hold the replacement admission slot forever.
                if timeoutEffect == .queueReplacement, self.queueReplacementToken == id {
                    self.effects.cancel(.queueReplacement)
                    self.queueReplacementToken = nil
                }
                return
            }
            let wasSent = self.state.intents.first(where: { $0.command.id == id })?.outcome == .sent
            if self.send(.commandTimedOut(id: id), source: .command, playbackLifetime: lifetime) {
                // A sent replacement may already have returned and released its slot.
                // Its observation deadline cannot cancel a newer replacement registration.
                let cancelExecution =
                    timeoutEffect == .queueReplacement ? self.queueReplacementToken == id : !wasSent
                if cancelExecution {
                    self.effects.cancel(timeoutEffect)
                    if timeoutEffect == .queueReplacement { self.queueReplacementToken = nil }
                }
                let dispatched = self.state.intents.first { $0.command.id == id }?.dispatchedAt != nil
                var message =
                    dispatched
                    ? "Spotify has not confirmed the queue request. Its result is unknown."
                    : "The queue request expired before it was sent."
                if cancelExecution, remainingRequests > 0 {
                    message +=
                        remainingRequests == 1
                        ? " The remaining queue request was not sent."
                        : " \(remainingRequests) remaining queue requests were not sent."
                }
                self.feedback.informational(message)
            }
        }
        return id
    }

    private func finishQueueIntent(
        _ id: UUID, outcome: Result<Void, PlaybackCommandFailure>,
        lifetime: PlaybackLifetime
    ) -> Bool? {
        guard stillCurrent(lifetime) else { return nil }
        let accepted: Bool
        if case .success = outcome { accepted = true } else { accepted = false }
        send(.queueIntentFinished(id: id, accepted: accepted), source: .command, playbackLifetime: lifetime)
        guard let intent = state.intents.first(where: { $0.command.id == id }) else { return nil }
        switch intent.outcome {
        case .superseded, .timedOut: return nil
        default: break
        }
        if case .failure(.reconnectRequired) = outcome { recoverEngineAfterCommandFailure() }
        return intent.outcome == .observedConfirmed || accepted
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
                let lifetime = playbackLifetime
                let route = ConnectCommandRoute.remote(from: from, to: to)
                let beforeEntries = presentationEntries
                guard
                    let intentID = startQueueIntent(
                        removing: Set(beforeEntries.filter { selectedIDs.contains($0.id) }.map(\.uid)),
                        timeoutEffect: .queueReplacement, lifetime: lifetime)
                else { return }
                let token = intentID
                queueReplacementToken = token
                effects.run(.queueReplacement) { [weak self] in
                    defer { self?.finishQueueReplacementIfCurrent(token) }
                    do {
                        guard let self else { return }
                        guard
                            let permit = self.makePlaybackDispatchPermit(
                                intentID: intentID,
                                ifStillWanted: {
                                    self.stillCurrent(lifetime, requiresConnection: true, route: route)
                                        && self.queueReplacementToken == token
                                })
                        else { return }
                        guard
                            let outcome = try await self.coordinator.performRemoteCommand(
                                { client in
                                    try await client.send(
                                        .setQueue(
                                            next: replacement.next,
                                            prev: replacement.prev,
                                            queueRevision: replacement.queueRevision
                                        ),
                                        from: from,
                                        to: to
                                    )
                                },
                                permit: permit
                            )
                        else { return }
                        guard
                            let accepted = self.finishQueueIntent(
                                intentID, outcome: outcome, lifetime: lifetime)
                        else { return }
                        if !accepted, case let .failure(error) = outcome { throw error }
                        guard
                            self.stillCurrent(lifetime, requiresConnection: true, route: route),
                            self.queueReplacementToken == token
                        else { return }
                        let mutation = await self.queueService.recordCommittedReplacement(
                            replacement,
                            accountEpoch: lifetime.accountEpoch,
                            engineEpoch: lifetime.engineGeneration
                        )
                        guard
                            self.stillCurrent(lifetime, requiresConnection: true, route: route),
                            self.queueReplacementToken == token
                        else { return }
                        if let mutation {
                            self.queueMutation = mutation
                        }
                        self.feedback.success(Self.removedFromQueueMessage(count: replacement.removedCount))
                    } catch {
                        guard let self,
                            self.stillCurrent(lifetime, requiresConnection: true, route: route),
                            self.queueReplacementToken == token
                        else { return }
                        guard self.queueNextEntries == beforeEntries else { return }
                        self.feedback.failure("Spotify couldn’t update the queue.")
                    }
                }
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

    private func finishQueueReplacementIfCurrent(_ token: UUID) {
        guard queueReplacementToken == token else { return }
        queueReplacementToken = nil
        if state.intents.first(where: { $0.command.id == token })?.outcome.isTerminal != false {
            effects.cancel(.commandDeadline(token))
        }
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
        count == 1 ? "Queue removal request sent" : "Queue removal request sent for \(count) songs"
    }

    /// Pulls the backend's last-known queue so the panel opens with content even
    /// before the next cluster update streams in.
    func refreshQueueSnapshot() {
        // Account-scoped: the decoded payload carries its own engine generation, which is
        // revalidated by the Connect callback watermark below rather than by store identity.
        let lifetime = playbackLifetime
        effects.run(.queueSnapshot) { [weak self] in
            guard let self,
                let state = await self.coordinator.queueSnapshot(),
                self.stillCurrent(lifetime, scope: .account, requiresConnection: true)
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
                accountEpoch: lifetime.accountEpoch,
                engineEpoch: state.sessionGeneration
            )
        }
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
        let lifetime = playbackLifetime
        effects.run(.queueRefresh) { [weak self] in
            guard let self else { return }
            guard
                let snapshot = await self.queueService.refresh(
                    fallbackEntries: self.queueNextEntries,
                    cachedTracks: cachedTracks,
                    currentTrackURI: self.trackURI.isEmpty ? nil : self.trackURI,
                    accountEpoch: lifetime.accountEpoch,
                    onUpdate: { [weak self] update in
                        guard let self, self.stillCurrent(lifetime, requiresConnection: true) else { return }
                        self.apply(update, engineEpoch: lifetime.engineGeneration)
                    }
                ), self.stillCurrent(lifetime, requiresConnection: true)
            else { return }
            self.apply(snapshot, engineEpoch: lifetime.engineGeneration)
        }
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
