import SpottyDiagnostics
//
//  PlaybackSessionRuntime+Commands.swift
//  Spotty
//
//  Command routing, outcomes, rollback, and notices.
//

import SpottyDomain
import SpottyRuntimeContracts
import SpottyEngineAdapter
import Foundation
import OSLog

extension PlaybackSessionRuntime {
    /// An intent with one meaning on either playback destination. Callers cannot independently
    /// choose the admission slot, wire operation, and optimistic state.
    enum CommandRequest: Sendable {
        case playURI(String)
        case playTrack(CatalogTrack)
        case playContext(uri: String, firstTrack: CatalogTrack?)
        case playTracks([CatalogTrack])
        case resume
        case pause
        case next
        case previous
        case seek(milliseconds: UInt32)
        case shuffle(Bool)
        case repeatMode(RepeatMode)
        case transfer(ConnectDevice)
    }

    typealias DispatchGuard = @SessionRuntimeActor @Sendable () -> Bool

    private enum RemoteCommand: Sendable {
        case single(SpotifyConnectCommand)
        case repeatTransition(RepeatTransitionPlan)
    }

    private enum CommandDispatch: Sendable {
        case local(LocalPlaybackOperation)
        case remote(RemoteCommand, from: String, to: String)
    }

    private struct PreparedCommand {
        let admission: PendingPlaybackCommand
        let dispatch: CommandDispatch
        let routeIsCurrent: DispatchGuard
    }

    /// Additional eligibility is checked after permit installation and cannot bypass route
    /// validation. Refusal before admission need not invoke the predicate.
    func submitCommand(
        _ request: CommandRequest,
        failureMessage: String,
        dispatchGuard: DispatchGuard? = nil,
        completion: @escaping @SessionRuntimeActor (Bool) -> Void = { _ in }
    ) {
        guard let prepared = prepareCommand(request) else {
            completion(false)
            return
        }
        let coordinator = coordinator
        let dispatch = prepared.dispatch
        let routeIsCurrent = prepared.routeIsCurrent
        performAdmittedPlaybackCommand(
            failureMessage, command: prepared.admission, completion: completion
        ) { [weak self] commandID in
            guard let self,
                let permit = self.makePlaybackDispatchPermit(
                    intentID: commandID,
                    ifStillWanted: { (dispatchGuard?() ?? true) && routeIsCurrent() })
            else { return nil }
            switch dispatch {
            case let .local(operation):
                return try await coordinator.performLocalCommand(operation, permit: permit)
            case let .remote(operation, from, to):
                return try await coordinator.performRemoteCommand(
                    { client in
                        switch operation {
                        case let .single(command):
                            try await client.send(command, from: from, to: to)
                        case let .repeatTransition(plan):
                            try await RepeatTransitionApplication.applyRemote(plan) { mutation in
                                try await client.send(.repeatMutation(mutation), from: from, to: to)
                            }
                        }
                    }, permit: permit)
            }
        }
    }

    private func prepareCommand(_ request: CommandRequest) -> PreparedCommand? {
        switch request {
        case let .playURI(uri):
            return preparePlay(uri: uri, firstTrack: nil)
        case let .playTrack(track):
            return preparePlay(uri: track.uri, firstTrack: track)
        case let .playContext(uri, firstTrack):
            return preparePlay(uri: uri, firstTrack: firstTrack)
        case let .playTracks(tracks):
            guard let first = tracks.first else { return nil }
            let uris = tracks.map(\.uri)
            let target = currentTrack(from: first)
            return prepareCommand(
                kind: .transport, local: .playTracks(uris), remote: .single(.play(trackURIs: uris)),
                transport: .playing, timing: playTargetTiming(from: target), track: target)
        case .resume:
            let target = PlaybackResumeTarget(
                trackURI: trackURI, contextURI: state.playbackContextURI,
                positionMS: UInt32(max(0, min(Double(UInt32.max), position * 1_000))),
                engineGeneration: engineGeneration)
            return prepareCommand(
                kind: .transport, local: .resumeObserved(target), remote: .single(.resume),
                transport: .playing,
                timing: PlaybackTiming(position: position, duration: duration, anchoredAt: environment.clock.now()))
        case .pause:
            let now = environment.clock.now()
            if isActiveDevice { refreshPosition() }
            return prepareCommand(
                kind: .transport, local: .pause, remote: .single(.pause), transport: .paused,
                timing: PlaybackTiming(position: displayedPosition(at: now), duration: duration, anchoredAt: now))
        case .next:
            return prepareCommand(kind: .navigation, local: .next, remote: .single(.next))
        case .previous:
            return prepareCommand(kind: .navigation, local: .previous, remote: .single(.previous))
        case let .seek(milliseconds):
            return prepareCommand(
                kind: .seek, local: .seek(milliseconds), remote: .single(.seek(to: Int(milliseconds))),
                timing: PlaybackTiming(
                    position: TimeInterval(milliseconds) / 1_000, duration: duration,
                    anchoredAt: environment.clock.now()))
        case let .shuffle(enabled):
            return prepareCommand(
                kind: .options, local: .shuffle(enabled), remote: .single(.shuffle(enabled)), shuffle: enabled)
        case let .repeatMode(mode):
            let flags = mode.flags
            let plan = RepeatTransitionPlan.planning(from: state.options.repeatFlags, to: flags)
            return prepareCommand(
                kind: .options, local: .repeatOptions(plan), remote: .repeatTransition(plan), repeatFlags: flags)
        case let .transfer(device):
            // Connect transfer is always an engine operation, including a remote destination.
            let isLocal = device.id == localDeviceID
            return prepareCommand(
                kind: .transfer, local: isLocal ? .transferToLocal : .transferToDevice(device.id), remote: nil,
                owner: isLocal
                    ? nil
                    : .uncertain(
                        PlaybackDevice(id: device.id, name: device.name, type: device.type, isActive: false)))
        }
    }

    private func preparePlay(uri: String, firstTrack: CatalogTrack?) -> PreparedCommand? {
        let value = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let target = firstTrack.map { currentTrack(from: $0) }
        return prepareCommand(
            kind: .transport, local: .playURI(value), remote: .single(.play(uri: value)),
            transport: .playing, timing: target.map { playTargetTiming(from: $0) }, track: target)
    }

    private func currentTrack(from track: CatalogTrack) -> CurrentTrack {
        CurrentTrack(
            uri: track.uri, title: track.title, artist: track.artist, artworkURL: track.artworkURL,
            duration: track.duration, metadataSource: .catalog)
    }

    private func playTargetTiming(from track: CurrentTrack) -> PlaybackTiming {
        PlaybackTiming(position: 0, duration: track.duration, anchoredAt: environment.clock.now())
    }

    /// Only the semantic request mapping above can construct correlated admission/dispatch data.
    /// Route refusal happens before optimistic state, and every accepted plan keeps its route.
    private func prepareCommand(
        kind: PlaybackCommandKind,
        local: LocalPlaybackOperation,
        remote: RemoteCommand?,
        transport: PlaybackTransportState? = nil,
        timing: PlaybackTiming? = nil,
        track: CurrentTrack? = nil,
        shuffle: Bool? = nil,
        repeatFlags: RepeatFlags? = nil,
        owner: PlaybackOwner? = nil
    ) -> PreparedCommand? {
        let dispatch: CommandDispatch
        let routeIsCurrent: DispatchGuard
        let isLocal: Bool
        if let remote {
            // Only play/resume requests carry `.playing`; other controls cannot activate an idle device.
            let defaultLocalID = transport == .playing ? defaultLocalPlaybackDevice?.id : nil
            let route: ConnectCommandRoute = defaultLocalID == nil ? commandRoute : .local
            switch route {
            case .local:
                SpottyLog.commands.info("Routing \(String(describing: kind), privacy: .public) command locally")
                dispatch = .local(local)
                isLocal = true
            case let .remote(from, to):
                SpottyLog.commands.info(
                    "Routing \(String(describing: kind), privacy: .public) command remotely; source=\(from, privacy: .private(mask: .hash)); target=\(to, privacy: .private(mask: .hash))"
                )
                dispatch = .remote(remote, from: from, to: to)
                isLocal = false
            case .waitingForLocalIdentity:
                SpottyLog.commands.notice("Command delayed while local Connect identity is unavailable")
                showTransientCommandError("Spotty is still joining Spotify Connect.")
                return nil
            case .needsDeviceSelection:
                SpottyLog.commands.notice("Command refused until a playback device is selected")
                showTransientCommandError(QueueMutationRefusal.needsDeviceSelection.feedbackMessage)
                return nil
            }
            routeIsCurrent = { [weak self] in
                guard let self else { return false }
                let currentRoute = self.commandRoute
                if currentRoute == route { return true }
                // Optimistic `.playing` hides the default-local projection. Keep the selected
                // device while this command's own transport admission remains pending.
                guard route == .local, let defaultLocalID,
                    self.state.pendingCommands[.transport]?.expectedTransport == .playing,
                    self.state.session == .ready,
                    self.state.devices.localDeviceID == defaultLocalID,
                    case .uncertain(nil) = self.state.owner,
                    currentRoute == .needsDeviceSelection
                else { return false }
                return true
            }
        } else {
            dispatch = .local(local)
            routeIsCurrent = { true }
            isLocal = true
        }
        return PreparedCommand(
            admission: PendingPlaybackCommand(
                id: UUID(), kind: kind, expectedTransport: transport, expectedTiming: timing,
                expectedTrack: track, expectedTrackURI: observationTrackURI(for: local),
                resumeTarget: isLocal ? observedResumeTarget(for: local) : nil,
                recoveryTarget: recoveryTarget(for: local, local: isLocal), expectedShuffle: shuffle,
                expectedRepeatFlags: repeatFlags, expectedOwner: owner, startedAt: environment.clock.now()),
            dispatch: dispatch, routeIsCurrent: routeIsCurrent)
    }

    private func observedResumeTarget(for operation: LocalPlaybackOperation) -> PlaybackResumeTarget? {
        if case let .resumeObserved(target) = operation { return target }
        return nil
    }

    private func recoveryTarget(for operation: LocalPlaybackOperation, local: Bool) -> PlaybackRecoveryTarget? {
        guard state.blockedResumeTarget != nil else { return nil }
        let selection: PlaybackRecoveryTarget.Selection
        switch operation {
        case let .playURI(uri):
            selection = uri.hasPrefix("spotify:track:") ? .track(uri) : .context(uri)
        case let .playTracks(uris):
            guard let first = uris.first else { return nil }
            selection = .track(first)
        default: return nil
        }
        return PlaybackRecoveryTarget(selection: selection, engineGeneration: engineGeneration, local: local)
    }

    private func observationTrackURI(for operation: LocalPlaybackOperation) -> String? {
        switch operation {
        case let .playURI(uri): uri.hasPrefix("spotify:track:") ? uri : nil
        case let .playTracks(uris): uris.first
        case let .resumeObserved(target): target.trackURI
        default: nil
        }
    }

    /// Admission, deadlines and reconciliation share one lifecycle for either dispatch destination.
    private func performAdmittedPlaybackCommand(
        _ action: String,
        command: PendingPlaybackCommand,
        completion: @escaping @SessionRuntimeActor (Bool) -> Void,
        operation: @escaping @SessionRuntimeActor (UUID) async throws -> Result<Void, PlaybackCommandFailure>?
    ) {
        let kind = command.kind
        // Lifecycle owns session admission; the reducer owns pending command identity.
        guard lifecycle.acceptsWork, state.pendingCommands[kind] == nil else {
            completion(false)
            return
        }
        let commandID = command.id
        let lifetime = playbackLifetime
        let started = send(
            .commandStarted(command),
            source: .command,
            playbackLifetime: lifetime
        )
        guard started else {
            completion(false)
            return
        }
        let deadlineID = PlaybackEffectID.commandDeadline(commandID)
        effects.run(deadlineID) { [weak self, clock = environment.clock] in
            // The timer belongs to the runtime; waiting must not keep that owner alive.
            do { try await clock.sleep(seconds: 8) } catch { return }
            guard let self, self.stillCurrent(lifetime) else { return }
            let wasSent = self.state.intents.first { $0.command.id == commandID }?.outcome == .sent
            let expiry = self.reduce(
                .commandTimedOut(id: commandID), source: .command,
                engineEpoch: lifetime.engineGeneration, accountEpoch: lifetime.accountEpoch)
            if expiry.accepted {
                self.effects.cancel(.command(commandID))
                if !wasSent { completion(false) }
                let dispatched = expiry.settledIntents.first { $0.id == commandID }?.dispatchedAt != nil
                self.showTransientCommandError(
                    dispatched
                        ? "Spotify has not confirmed this request. Its result is unknown."
                        : "The playback request expired before it was sent.")
            }
        }
        let effectID = PlaybackEffectID.command(commandID)
        effects.run(
            effectID,
            onCancel: { [weak self] in
                self?.settleCancelledPlaybackCommand(
                    commandID: commandID,
                    kind: kind,
                    capturedLifetime: lifetime,
                    completion: completion
                )
            }
        ) { [weak self] in
            guard let self else { return }
            do {
                // Admission publishes optimistic state before this effect gets a turn. A
                // session/engine publication may invalidate that state while the task is
                // queued. Re-check both lifetime and command identity before creating a
                // dispatch permit; otherwise stale work could acquire a fresh permit in the
                // replacement lifetime and reach local C or the remote client after its
                // pending intent was already dropped.
                guard
                    self.stillCurrent(lifetime),
                    self.state.pendingCommands[kind]?.id == commandID
                else {
                    self.settleUndispatchedPlaybackCommand(
                        commandID: commandID,
                        kind: kind,
                        capturedLifetime: lifetime,
                        completion: completion
                    )
                    return
                }
                guard let outcome = try await operation(commandID) else {
                    self.settleUndispatchedPlaybackCommand(
                        commandID: commandID,
                        kind: kind,
                        capturedLifetime: lifetime,
                        completion: completion
                    )
                    return
                }
                // Account replacement and teardown make every outcome inert here. Engine
                // replacement is intentionally resolved by the lifetime-stamped reducer
                // finish and shared follow-up: an authoritative engine sample may confirm
                // or supersede a command while its coordinator operation is suspended, so this
                // gate is deliberately account-scoped.
                guard self.stillCurrent(lifetime, scope: .account) else { return }
                self.applyCommandOutcome(
                    commandID: commandID,
                    capturedLifetime: lifetime,
                    outcome: outcome,
                    action: action,
                    completion: completion
                )
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    /// A route/lifetime check can refuse a command after its optimistic reducer state was
    /// admitted but before the coordinator entered local C or remote transport. Settle that
    /// command through the same reducer finish path, without presenting a transport failure.
    private func settleUndispatchedPlaybackCommand(
        commandID: UUID,
        kind: PlaybackCommandKind,
        capturedLifetime: PlaybackLifetime,
        completion: @escaping @SessionRuntimeActor (Bool) -> Void
    ) {
        guard
            playbackCommandShouldSettleUndispatched(
                pendingCommandID: state.pendingCommands[kind]?.id,
                undispatchedCommandID: commandID,
                capturedLifetime: capturedLifetime,
                currentLifetime: playbackLifetime,
                isTearingDown: isTearingDown
            )
        else { return }
        let finished = send(
            .commandFinished(id: commandID, accepted: false, notice: nil),
            source: .command,
            playbackLifetime: capturedLifetime
        )
        guard finished else { return }
        completion(false)
    }

    /// Ordinary same-lifetime `PlaybackEffectID.command` cancellation. Matching pending
    /// identity is the once-gate: restore reducer-owned rollback, clear that command,
    /// and report `completion(false)` without a notice or reconnect. Confirmed,
    /// superseded, stale, and teardown paths stay inert.
    private func settleCancelledPlaybackCommand(
        commandID: UUID,
        kind: PlaybackCommandKind,
        capturedLifetime: PlaybackLifetime,
        completion: @escaping @SessionRuntimeActor (Bool) -> Void
    ) {
        guard
            playbackCommandShouldSettleOrdinaryCancellation(
                pendingCommandID: state.pendingCommands[kind]?.id,
                cancelledCommandID: commandID,
                capturedLifetime: capturedLifetime,
                currentLifetime: playbackLifetime,
                isTearingDown: isTearingDown
            )
        else { return }
        let finished = send(
            .commandFinished(id: commandID, accepted: false, notice: nil),
            source: .command,
            playbackLifetime: capturedLifetime
        )
        guard finished else { return }
        completion(false)
    }

    /// Local and remote command finishes share this policy so a matching engine snapshot cannot
    /// drop `play` / `togglePlayback` / shuffle / repeat / remote-transfer completions, including
    /// when the coordinator later fails. The finished command's resolution is captured before
    /// `commandFinished` so follow-up can treat consume-only reducer acceptance as confirmed
    /// success or superseded inertness.
    /// Epoch invalidation, teardown, supersession, and rejected finishes without a captured
    /// confirmation stay inert.
    private func applyCommandOutcome(
        commandID: UUID,
        capturedLifetime: PlaybackLifetime,
        outcome: Result<Void, PlaybackCommandFailure>,
        action: String,
        completion: @escaping @SessionRuntimeActor (Bool) -> Void
    ) {
        let succeeded: Bool
        let requiresReconnect: Bool
        let notice: PlaybackNotice?
        switch outcome {
        case .success:
            succeeded = true
            requiresReconnect = false
            notice = nil
        case let .failure(failure):
            succeeded = false
            requiresReconnect = failure == .reconnectRequired
            notice =
                failure == .resumeMismatch
                ? PlaybackNotice(message: PlaybackNotice.resumeUnavailableMessage, kind: .resumeUnavailable)
                : PlaybackNotice(message: action)
        }
        let capturedResolution = state.transportCommandResolutions[commandID]
        let finished = send(
            .commandFinished(
                id: commandID,
                accepted: succeeded,
                notice: notice
            ),
            source: .command,
            playbackLifetime: capturedLifetime
        )
        switch playbackCommandFollowUp(
            finishAccepted: finished,
            operationSucceeded: succeeded,
            requiresReconnect: requiresReconnect,
            finishedCommandResolution: capturedResolution,
            capturedLifetime: capturedLifetime,
            currentLifetime: playbackLifetime,
            isTearingDown: isTearingDown
        ) {
        case .reportSuccess:
            completion(true)
        case .reconnectAfterReconciledSuccess:
            // The snapshot already settled what the UI shows; the engine still lost its
            // session under this command. No notice, no rollback, but rebuild the connection.
            completion(true)
            recoverEngineAfterCommandFailure()
        case let .reportFailure(reconnect):
            if let notice {
                if notice.kind == .resumeUnavailable {
                    send(.notice(notice), source: .command, playbackLifetime: capturedLifetime)
                } else {
                    showTransientCommandError(notice.message)
                }
            }
            completion(false)
            if reconnect {
                recoverEngineAfterCommandFailure()
            }
        case .inert:
            if let notice, notice.kind == .resumeUnavailable,
                state.intents.last?.command.id == commandID,
                stillCurrent(capturedLifetime, requiresConnection: true)
            {
                send(.notice(notice), source: .command, playbackLifetime: capturedLifetime)
            }
            break
        }
    }

    /// Rebuilds the engine connection after a reconnect-required command failure.
    ///
    /// `AccountStore.connect()` only starts a connection while the account is not `.ready`.
    /// A closed Spirc command channel or a lost session is reported by the engine while the
    /// account is usually still `.ready` (the engine does not mark itself disconnected on that
    /// classification), so a ready account goes through the engine's own rebuild, the same
    /// `forceReconnect` path sleep/wake uses. Anything else falls back to the account connect.
    func recoverEngineAfterCommandFailure() {
        guard isConnected else {
            connect()
            return
        }
        effects.run(.engineRecovery) { [weak self] in
            guard let self, !Task.isCancelled else { return }
            _ = await self.coordinator.forceReconnect()
        }
    }

    func showTransientCommandError(_ message: String) {
        guard let noticeID = setNotice(message) else { return }
        // Dismissal is identified by the notice it published, so it deliberately does not
        // revalidate a lifetime: a reset already replaced the notice this would clear.
        effects.run(.commandError) { [weak self] in
            try? await self?.environment.clock.sleep(seconds: 4)
            guard !Task.isCancelled else { return }
            self?.dismissPlaybackNotice(id: noticeID)
        }
    }

}
