import Foundation
import SpottyDomain
import SpottyRuntimeContracts

/// Child effects inherit correlation; a late task from a retired account cannot attach itself to
/// a newly admitted command that happens to reuse an ID.
package enum ServiceCommandContext {
    @TaskLocal package static var command: SessionCommand?
}

extension PlaybackSessionRuntime: SessionRuntimeServing {
    package func snapshot() async -> SessionSnapshot {
        flushPublication()
        synchronizeServiceReceipts()
        return serviceSnapshot()
    }

    package func subscribe() async -> AsyncStream<SessionSnapshot> {
        flushPublication()
        let id = UUID()
        let pair = AsyncStream<SessionSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(8))
        serviceSubscribers[id] = pair.continuation
        pair.continuation.yield(serviceSnapshot())
        pair.continuation.onTermination = { [weak self] _ in
            Task { @SessionRuntimeActor in self?.serviceSubscribers[id] = nil }
        }
        return pair.stream
    }

    package func submit(_ command: SessionCommand) async -> SessionCommandReceipt {
        guard command.sessionID == sessionID else {
            return serviceReceipt(command, .rejected, "The account session changed.")
        }
        synchronizeServiceReceipts()
        if let previous = serviceCommandLedger[command.id] { return previous }
        // Never evict a replay fence to make room. Reconnecting does not create a new session.
        guard serviceCommandLedger.count < 4_096 || command.action == .logout else {
            return serviceReceipt(
                command, .rejected, "This session has reached its command limit. Reconnect the account.")
        }
        if let reason = serviceRefusal(command) {
            return rememberServiceReceipt(command, .rejected, reason)
        }
        guard serviceCommandActions.count < 64 || command.action == .logout || command.action == .cancelConnect else {
            return rememberServiceReceipt(command, .rejected, "Too many requests are still awaiting a result.")
        }
        serviceCommandActions[command.id] = command.action
        serviceCommandEpochs[command.id] = accountEpoch
        _ = rememberServiceReceipt(command, .admitted)
        armServiceDeadline(command)
        return await ServiceCommandContext.$command.withValue(command) {
            await executeServiceCommand(command)
        }
    }
}

package extension PlaybackSessionRuntime {
    /// Called synchronously after reducer acceptance, before publication can be coalesced. This
    /// captures every queue occurrence intent, including those created by a later child effect.
    func recordServiceIntent(_ event: PlaybackEvent) {
        guard let command = ServiceCommandContext.command, command.sessionID == sessionID,
            serviceCommandLedger[command.id]?.disposition.isTerminal == false
        else { return }
        let id: UUID
        switch event {
        case let .commandStarted(pending): id = pending.id
        case let .queueIntentStarted(intent): id = intent.command.id
        default: return
        }
        if serviceIntentIDs[command.id, default: []].contains(id) { return }
        serviceIntentIDs[command.id, default: []].append(id)
    }

    func synchronizeServiceReceipts() {
        for id in Array(serviceCommandActions.keys) {
            guard let receipt = serviceCommandLedger[id], !receipt.disposition.isTerminal else { continue }
            let intentIDs = serviceIntentIDs[id, default: []]
            for intentID in intentIDs {
                guard let intent = state.intents.first(where: { $0.command.id == intentID }) else { continue }
                let disposition: SessionCommandDisposition =
                    switch intent.outcome {
                    case .admitted: .admitted
                    case .dispatched: .dispatched
                    case .sent: .sent
                    case .observedConfirmed: .observedConfirmed
                    case .rejected: .rejected
                    case .superseded: .superseded
                    case .timedOut: intent.dispatchedAt == nil ? .expired : .unknown
                    }
                serviceIntentOutcomes[intentID] = disposition
            }
            guard !intentIDs.isEmpty else { continue }
            let outcomes = intentIDs.compactMap { serviceIntentOutcomes[$0] }
            let expectedCount: Int
            if case let .addToQueue(uris) = serviceCommandActions[id] {
                expectedCount = uris.count
            } else {
                expectedCount = 1
            }
            let disposition = serviceAggregateDisposition(outcomes, expectedCount: expectedCount)
            if disposition != receipt.disposition {
                updateServiceReceipt(id, disposition)
            }
        }
    }

    private func executeServiceCommand(_ command: SessionCommand) async -> SessionCommandReceipt {
        switch command.action {
        case .restore:
            effects.run(.serviceAccountReceipt(command.id)) { [weak self] in
                guard let self, command.sessionID == self.sessionID else { return }
                await self.restore()
                _ = self.finishServiceAccountCommand(command, restored: true)
            }
            return serviceCommandLedger[command.id] ?? serviceReceipt(command, .unknown)
        case .connect, .reauthorize:
            if command.action == .connect { connect() } else { reauthorize() }
            let connection = accountStore.connectionSettlement
            effects.run(.serviceAccountReceipt(command.id)) { [weak self] in
                await connection?.value
                guard let self else { return }
                _ = self.finishServiceAccountCommand(command, restored: false)
            }
            return serviceCommandLedger[command.id] ?? serviceReceipt(command, .unknown)
        case .logout:
            await logout()
            // Logout deliberately retires its original session. A logout coalesced into an
            // already-running teardown can retain the session under which it was admitted.
            let disposition: SessionCommandDisposition =
                !isTearingDown && accountStore.phase == .signedOut ? .observedConfirmed : .unknown
            if command.sessionID == sessionID {
                updateServiceReceipt(command.id, disposition)
                publish()
            }
            return serviceReceipt(command, disposition)
        case .cancelConnect:
            cancelConnect()
            updateServiceReceipt(command.id, .observedConfirmed)
        case let .playURI(uri): play(uri: uri)
        case let .playTracks(tracks, _):
            let first = tracks[0]
            let expected = CurrentTrack(
                uri: first.uri, title: first.title, artist: first.artist,
                artworkURL: first.artworkURL, duration: first.duration, metadataSource: .catalog)
            performRoutedCommand(
                "Could not play those tracks", expecting: true,
                expectedTiming: PlaybackTiming(duration: expected.duration, anchoredAt: environment.clock.now()),
                expectedTrack: expected, local: .playTracks(tracks.map(\.uri)),
                remote: .play(trackURIs: tracks.map(\.uri)))
        case .togglePlayback: togglePlayback()
        case .next: next()
        case .previous: previous()
        case let .seek(fraction): seek(to: fraction)
        case .toggleShuffle:
            let hadLiveOwner = isActiveDevice || activeRemoteDevice != nil
            toggleShuffle()
            if !hadLiveOwner { updateServiceReceipt(command.id, .observedConfirmed) }
        case .cycleRepeat: cycleRepeat()
        case let .transfer(requested):
            // Device labels and activation flags are runtime truth, never client authority.
            if let device = presentedDevices.first(where: { $0.id == requested.id }) { transferPlayback(to: device) }
        case let .addToQueue(uris): addToQueue(uris: uris)
        case let .removeUpcoming(selectedIDs): removeUpcomingQueueOccurrences(selectedIDs: selectedIDs)
        case .refreshQueue:
            let before = state.queue
            refreshQueue()
            let refresh = effects.settlement(of: .queueRefresh)
            let snapshot = effects.settlement(of: .queueSnapshot)
            await refresh?.wait()
            await snapshot?.wait()
            guard command.sessionID == sessionID else { return serviceReceipt(command, .superseded) }
            updateServiceReceipt(command.id, state.queue != before ? .observedConfirmed : .unknown)
        case .cancelQueueRefresh:
            cancelQueueRefresh()
            updateServiceReceipt(command.id, .observedConfirmed)
        }
        guard command.sessionID == sessionID else { return serviceReceipt(command, .superseded) }
        synchronizeServiceReceipts()
        // Queue adds create their occurrence intents inside the registered child effect. Other
        // playback controls admit synchronously; no intent means their existing gate refused them.
        if command.action.kind != .queueAppend, command.action.kind != .queueRefresh,
            serviceCommandLedger[command.id]?.disposition == .admitted,
            serviceIntentIDs[command.id, default: []].isEmpty
        {
            updateServiceReceipt(command.id, .rejected, "This action could not be admitted.")
        }
        publish()
        return serviceCommandLedger[command.id] ?? serviceReceipt(command, .unknown)
    }

    private func finishServiceAccountCommand(
        _ command: SessionCommand, restored: Bool
    ) -> SessionCommandReceipt {
        guard command.sessionID == sessionID else { return serviceReceipt(command, .superseded) }
        let disposition: SessionCommandDisposition
        switch accountStore.phase {
        case .ready: disposition = .observedConfirmed
        case .signedOut: disposition = restored ? .observedConfirmed : .rejected
        case .failed: disposition = .rejected
        default: disposition = .unknown
        }
        updateServiceReceipt(command.id, disposition)
        publish()
        return serviceCommandLedger[command.id] ?? serviceReceipt(command, .unknown)
    }

    private func armServiceDeadline(_ command: SessionCommand) {
        effects.run(.serviceReceiptDeadline(command.id)) { [weak self] in
            guard let self else { return }
            // Account authorization is user paced. Queue occurrences dispatch sequentially,
            // each with its own eight-second reducer deadline; a healthy batch must not expire
            // merely because its aggregate duration exceeds one occurrence's allowance.
            let seconds: TimeInterval
            switch command.action {
            case let .addToQueue(uris): seconds = 8 * Double(uris.count)
            default: seconds = command.action.kind == .account ? 300 : 8
            }
            do { try await self.environment.clock.sleep(seconds: seconds) } catch { return }
            guard command.sessionID == self.sessionID,
                self.serviceCommandLedger[command.id]?.disposition.isTerminal == false
            else { return }
            self.synchronizeServiceReceipts()
            // Only the reducer's permit-linearized timeout may prove a write expired before
            // dispatch. A service deadline cannot revoke an already queued worker by inference.
            self.updateServiceReceipt(command.id, .unknown)
            self.publish()
        }
    }

    private func serviceRefusal(_ command: SessionCommand) -> String? {
        if let expected = command.expectedRouteRevision, expected != routeRevision {
            return "The playback destination changed."
        }
        guard terminationGate.allowsCommands else { return "Spotty is shutting down." }
        guard !isTearingDown || command.action == .logout else { return "The account session is being retired." }
        if let reason = invalidServiceAction(command.action) { return reason }
        switch command.action {
        case .restore, .connect, .reauthorize:
            guard accountStore.canStartConnection,
                !serviceCommandActions.values.contains(where: {
                    switch $0 {
                    case .restore, .connect, .reauthorize: true;
                    default: false
                    }
                })
            else { return "An account connection is already active." }
        case .cancelConnect:
            guard state.session == .authorizing else { return "No authorization is awaiting cancellation." }
        case .logout: break
        case let .transfer(device):
            guard let current = presentedDevices.first(where: { $0.id == device.id }),
                !current.isActive, current.id != activeRemoteDevice?.id
            else { return "That playback device is no longer available." }
        case .seek:
            guard duration.isFinite, (0...Double(UInt32.max) / 1_000).contains(duration) else {
                return "The current track has no valid seek duration."
            }
        case let .removeUpcoming(ids):
            guard canRemoveUpcomingQueue(selectedIDs: ids) else {
                return "Those queue entries can no longer be removed."
            }
        default: break
        }
        guard serviceCapabilities().contains(command.action.kind) else {
            return "This action is unavailable."
        }
        if command.action.kind == .queueAppend {
            switch commandRoute {
            case .local, .remote: break
            case .waitingForLocalIdentity, .needsDeviceSelection: return "Select an available playback device first."
            }
        }
        return nil
    }

    private func rememberServiceReceipt(
        _ command: SessionCommand, _ disposition: SessionCommandDisposition, _ message: String? = nil
    ) -> SessionCommandReceipt {
        let receipt = serviceReceipt(command, disposition, message)
        serviceCommandLedger[command.id] = receipt
        serviceReceipts.removeAll { $0.commandID == command.id }
        serviceReceipts.append(receipt)
        if serviceReceipts.count > 128 { serviceReceipts.removeFirst(serviceReceipts.count - 128) }
        publish()
        return receipt
    }

    private func updateServiceReceipt(
        _ id: UUID, _ disposition: SessionCommandDisposition, _ message: String? = nil
    ) {
        guard let previous = serviceCommandLedger[id], !previous.disposition.isTerminal else { return }
        let receipt = SessionCommandReceipt(
            commandID: id, sessionID: previous.sessionID, disposition: disposition, message: message)
        serviceCommandLedger[id] = receipt
        if let index = serviceReceipts.firstIndex(where: { $0.commandID == id }) {
            serviceReceipts[index] = receipt
        } else {
            serviceReceipts.append(receipt)
            if serviceReceipts.count > 128 { serviceReceipts.removeFirst(serviceReceipts.count - 128) }
        }
        if disposition.isTerminal {
            effects.cancel(.serviceReceiptDeadline(id))
            effects.cancel(.serviceAccountReceipt(id))
            for intentID in serviceIntentIDs.removeValue(forKey: id) ?? [] { serviceIntentOutcomes[intentID] = nil }
            serviceCommandActions[id] = nil
            serviceCommandEpochs[id] = nil
        }
    }
}

private func serviceReceipt(
    _ command: SessionCommand, _ disposition: SessionCommandDisposition, _ message: String? = nil
) -> SessionCommandReceipt {
    SessionCommandReceipt(
        commandID: command.id, sessionID: command.sessionID, disposition: disposition, message: message)
}

package func serviceAggregateDisposition(
    _ outcomes: [SessionCommandDisposition], expectedCount: Int
) -> SessionCommandDisposition {
    let dispatched = outcomes.contains { [.dispatched, .sent, .observedConfirmed, .unknown].contains($0) }
    if outcomes.contains(.unknown) { return .unknown }
    for terminal in [SessionCommandDisposition.rejected, .expired, .superseded] where outcomes.contains(terminal) {
        return dispatched ? .unknown : terminal
    }
    if outcomes.count == expectedCount, outcomes.allSatisfy({ $0 == .observedConfirmed }) { return .observedConfirmed }
    if outcomes.count == expectedCount, outcomes.allSatisfy({ $0 == .sent || $0 == .observedConfirmed }) {
        return .sent
    }
    return dispatched ? .dispatched : .admitted
}

private func invalidServiceAction(_ action: SessionAction) -> String? {
    func valid(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 4_096 }
    func playable(_ value: String) -> Bool { valid(value) && value.hasPrefix("spotify:") }
    switch action {
    case let .playURI(uri):
        if !playable(uri) { return "A valid Spotify URI is required." }
    case let .playTracks(tracks, contextURI):
        if tracks.isEmpty || tracks.count > 256
            || !tracks.allSatisfy({
                playable($0.uri) && $0.duration.isFinite && (0...Double(UInt32.max) / 1_000).contains($0.duration)
            }) || contextURI.map({ !playable($0) }) == true
        {
            return "The requested track list is invalid."
        }
    case let .addToQueue(uris):
        if uris.isEmpty || uris.count > 256 || !uris.allSatisfy(playable) {
            return "The requested queue entries are invalid."
        }
    case let .removeUpcoming(ids):
        if ids.isEmpty || ids.count > 256 || !ids.allSatisfy(valid) {
            return "The requested queue selection is invalid."
        }
    case let .seek(fraction):
        if !fraction.isFinite || !(0...1).contains(fraction) { return "The seek position is invalid." }
    case let .transfer(device):
        if !valid(device.id) { return "The requested playback device is invalid." }
    default: break
    }
    return nil
}
