//
//  PlaybackStore+Commands.swift
//  Spotty
//
//  Command routing, outcomes, rollback, and notices.
//

import SpottyDomain
import Foundation
import OSLog

extension PlaybackStore {
    func performCommand(
        _ action: String,
        expecting expectedPlaybackState: Bool? = nil,
        expectedTiming: PlaybackTiming? = nil,
        expectedTrack: CurrentTrack? = nil,
        expectedShuffle: Bool? = nil,
        expectedRepeatFlags: RepeatFlags? = nil,
        expectedOwner: PlaybackOwner? = nil,
        operation: LocalPlaybackOperation,
        kind: PlaybackCommandKind = .transport,
        completion: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        let coordinator = coordinator
        performAdmittedPlaybackCommand(
            action,
            kind: kind,
            expecting: expectedPlaybackState,
            expectedTiming: expectedTiming,
            expectedTrack: expectedTrack,
            expectedShuffle: expectedShuffle,
            expectedRepeatFlags: expectedRepeatFlags,
            expectedOwner: expectedOwner,
            completion: completion
        ) {
            try await coordinator.performLocalCommand(operation)
        }
    }

    func performRoutedCommand(
        _ action: String,
        kind: PlaybackCommandKind = .transport,
        expecting expectedPlaybackState: Bool? = nil,
        expectedTiming: PlaybackTiming? = nil,
        expectedTrack: CurrentTrack? = nil,
        expectedShuffle: Bool? = nil,
        expectedRepeatFlags: RepeatFlags? = nil,
        expectedOwner: PlaybackOwner? = nil,
        local: LocalPlaybackOperation,
        remote command: SpotifyConnectCommand,
        completion: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        performRoutedOperation(
            action,
            kind: kind,
            expecting: expectedPlaybackState,
            expectedTiming: expectedTiming,
            expectedTrack: expectedTrack,
            expectedShuffle: expectedShuffle,
            expectedRepeatFlags: expectedRepeatFlags,
            expectedOwner: expectedOwner,
            local: local,
            remote: { api, from, to in try await api.send(command, from: from, to: to) },
            completion: completion
        )
    }

    func performRoutedOperation(
        _ action: String,
        kind: PlaybackCommandKind = .transport,
        expecting expectedPlaybackState: Bool? = nil,
        expectedTiming: PlaybackTiming? = nil,
        expectedTrack: CurrentTrack? = nil,
        expectedShuffle: Bool? = nil,
        expectedRepeatFlags: RepeatFlags? = nil,
        expectedOwner: PlaybackOwner? = nil,
        local: LocalPlaybackOperation,
        remote: @escaping @Sendable (any RemotePlaybackClient, String, String) async throws -> Void,
        completion: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        switch commandRoute {
        case .local:
            SpottyLog.commands.info("Routing \(String(describing: kind), privacy: .public) command locally")
            performCommand(
                action,
                expecting: expectedPlaybackState,
                expectedTiming: expectedTiming,
                expectedTrack: expectedTrack,
                expectedShuffle: expectedShuffle,
                expectedRepeatFlags: expectedRepeatFlags,
                expectedOwner: expectedOwner,
                operation: local,
                kind: kind,
                completion: completion
            )
        case .waitingForLocalIdentity:
            SpottyLog.commands.notice("Command delayed while local Connect identity is unavailable")
            showTransientCommandError("Spotty is still joining Spotify Connect.")
            completion(false)
        case .needsDeviceSelection:
            SpottyLog.commands.notice("Command refused until a playback device is selected")
            showTransientCommandError(QueueMutationRefusal.needsDeviceSelection.feedbackMessage)
            completion(false)
        case let .remote(from, to):
            SpottyLog.commands.info(
                "Routing \(String(describing: kind), privacy: .public) command remotely; source=\(from, privacy: .private(mask: .hash)); target=\(to, privacy: .private(mask: .hash))"
            )
            let coordinator = coordinator
            performAdmittedPlaybackCommand(
                action,
                kind: kind,
                expecting: expectedPlaybackState,
                expectedTiming: expectedTiming,
                expectedTrack: expectedTrack,
                expectedShuffle: expectedShuffle,
                expectedRepeatFlags: expectedRepeatFlags,
                expectedOwner: expectedOwner,
                completion: completion
            ) {
                try await coordinator.performRemoteCommand { client in
                    try await remote(client, from, to)
                }
            }
        }
    }

    /// Shared playback-command lifecycle kernel. Route selection, route refusal, and
    /// waiting-for-local-identity stay outside so they cannot create pending commands.
    /// Callers supply the local or remote operation after choosing a live route.
    private func performAdmittedPlaybackCommand(
        _ action: String,
        kind: PlaybackCommandKind,
        expecting expectedPlaybackState: Bool?,
        expectedTiming: PlaybackTiming?,
        expectedTrack: CurrentTrack?,
        expectedShuffle: Bool?,
        expectedRepeatFlags: RepeatFlags?,
        expectedOwner: PlaybackOwner?,
        completion: @escaping @MainActor (Bool) -> Void,
        operation: @escaping @MainActor () async throws -> Result<Void, PlaybackCommandFailure>
    ) {
        guard
            playbackCommandShouldAdmit(
                isTearingDown: isTearingDown,
                allowsCommands: terminationGate.allowsCommands,
                hasPendingCommandForKind: state.pendingCommands[kind] != nil
            )
        else {
            completion(false)
            return
        }
        let commandID = UUID()
        let lifetime = playbackLifetime
        let started = send(
            .commandStarted(
                PendingPlaybackCommand(
                    id: commandID,
                    kind: kind,
                    expectedTransport: expectedPlaybackState.map { $0 ? .playing : .paused },
                    expectedTiming: expectedTiming,
                    expectedTrack: expectedTrack,
                    expectedShuffle: expectedShuffle,
                    expectedRepeatFlags: expectedRepeatFlags,
                    expectedOwner: expectedOwner,
                    startedAt: environment.clock.now()
                )),
            source: .command,
            playbackLifetime: lifetime
        )
        guard started else {
            completion(false)
            return
        }
        let effectID = PlaybackEffectID.command(commandID)
        let registration = PlaybackEffectRegistration()
        effects.replace(
            effectID,
            with: Task { [weak self] in
                defer { self?.effects.complete(effectID, registration: registration) }
                guard let self else { return }
                do {
                    let outcome = try await operation()
                    // Account replacement and teardown make every outcome inert here. Engine
                    // replacement is intentionally resolved by the lifetime-stamped reducer
                    // finish and shared follow-up: an authoritative engine sample may confirm
                    // or supersede a command while its coordinator operation is suspended.
                    guard
                        !Task.isCancelled,
                        lifetime.accountEpoch == self.accountEpoch,
                        !self.isTearingDown
                    else { return }
                    self.applyCommandOutcome(
                        commandID: commandID,
                        kind: kind,
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
            },
            registration: registration,
            onCancel: { [weak self] in
                self?.settleCancelledPlaybackCommand(
                    commandID: commandID,
                    kind: kind,
                    capturedLifetime: lifetime,
                    completion: completion
                )
            }
        )
    }

    /// Ordinary same-lifetime `PlaybackEffectID.command` cancellation. Matching pending
    /// identity is the once-gate: restore reducer-owned rollback, clear that command,
    /// and report `completion(false)` without a notice or reconnect. Confirmed,
    /// superseded, stale, and teardown paths stay inert.
    private func settleCancelledPlaybackCommand(
        commandID: UUID,
        kind: PlaybackCommandKind,
        capturedLifetime: PlaybackLifetime,
        completion: @escaping @MainActor (Bool) -> Void
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
    /// Epoch, teardown, unknown ids, and options finishes without a captured confirmation stay
    /// inert.
    private func applyCommandOutcome(
        commandID: UUID,
        kind: PlaybackCommandKind,
        capturedLifetime: PlaybackLifetime,
        outcome: Result<Void, PlaybackCommandFailure>,
        action: String,
        completion: @escaping @MainActor (Bool) -> Void
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
            notice = PlaybackNotice(message: action)
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
            commandKind: kind,
            pendingCommandID: state.pendingCommands[kind]?.id,
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
                showTransientCommandError(notice.message)
            }
            completion(false)
            if reconnect {
                recoverEngineAfterCommandFailure()
            }
        case .inert:
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
        effects.replace(
            .engineRecovery,
            with: Task { [weak self] in
                guard let self, !Task.isCancelled else { return }
                _ = await self.coordinator.forceReconnect()
            })
    }

    func showTransientCommandError(_ message: String) {
        guard let noticeID = setNotice(message) else { return }
        effects.replace(
            .commandError,
            with: Task { [weak self] in
                try? await self?.environment.clock.sleep(seconds: 4)
                guard !Task.isCancelled else { return }
                self?.dismissPlaybackNotice(id: noticeID)
            })
    }

}
