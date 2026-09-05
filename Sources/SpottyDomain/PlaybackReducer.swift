import Foundation

public enum PlaybackReducer {
    /// Query-only epoch and ordered-source revision gates. A `true` result does not record the
    /// revision; only a successful `reduce` may mutate `PlaybackState`.
    public static func accepts(
        _ state: PlaybackState,
        accountEpoch: UInt64,
        engineEpoch: UInt64,
        source: PlaybackEventSource,
        revision: UInt64?
    ) -> Bool {
        adopting(
            state,
            accountEpoch: accountEpoch,
            engineEpoch: engineEpoch,
            source: source,
            revision: revision
        ) != nil
    }

    @discardableResult
    public static func reduce(
        _ state: inout PlaybackState,
        envelope: PlaybackEventEnvelope
    ) -> Bool {
        // Reduce into a candidate so a rejected event is genuinely inert. In particular, an
        // unknown command acknowledgement must not consume its source revision and prevent the
        // matching acknowledgement from arriving later.
        guard
            var candidate = adopting(
                state,
                accountEpoch: envelope.accountEpoch,
                engineEpoch: envelope.engineEpoch,
                source: envelope.source,
                revision: envelope.revision
            )
        else { return false }

        switch envelope.event {
        case let .reset(session):
            candidate = PlaybackState(
                accountEpoch: envelope.accountEpoch,
                engineEpoch: envelope.engineEpoch,
                session: session
            )
        case let .session(session):
            candidate.session = session
        case let .owner(owner):
            reconcileOwner(owner, source: envelope.source, in: &candidate)
        case let .enginePlayback(snapshot):
            let incomingURI = playbackTrackURI(snapshot.trackURI)
            // A one-shot failure that names anything other than an optimistic play target is a
            // stale callback. Reject it before identity, transport, or source revision changes so
            // the newer target remains visible and a later matching sample can still be accepted.
            if snapshot.trackUnavailable,
                let expectedURI = playbackTrackURI(candidate.pendingCommands[.transport]?.expectedTrack?.uri),
                incomingURI != expectedURI
            {
                return false
            }
            if shouldHoldOptimisticPlayTarget(incomingURI: incomingURI, in: candidate) {
                applyEnginePlaybackOptions(snapshot, in: &candidate)
            } else {
                supersedeOptimisticPlayTargetIfNeeded(incomingURI: incomingURI, in: &candidate)
                let previousURI = candidate.currentTrack?.uri
                if let context = snapshot.contextURI {
                    candidate.playbackContextURI = playbackTrackURI(context)
                }
                reconcileSeekTiming(
                    snapshot.timing,
                    incomingTrackURI: incomingURI,
                    recordsAuthoritativeSample: true,
                    in: &candidate
                )
                if let uri = incomingURI {
                    if candidate.currentTrack?.uri != uri {
                        candidate.currentTrack = CurrentTrack(uri: uri)
                    }
                } else {
                    candidate.currentTrack = nil
                }
                adoptOwnerAfterTrackURIChange(
                    previousURI: previousURI,
                    incomingURI: incomingURI,
                    source: envelope.source,
                    in: &candidate
                )
                applyEnginePlaybackOptions(snapshot, in: &candidate)
                reconcileTransport(
                    candidate.currentTrack == nil ? .stopped : snapshot.transport,
                    incomingTrackURI: incomingURI,
                    isTrackUnavailable: snapshot.trackUnavailable,
                    in: &candidate
                )
                if snapshot.trackUnavailable, incomingURI != nil {
                    candidate.notice = PlaybackNotice(message: PlaybackNotice.trackUnavailableMessage)
                }
            }
        case let .engineConnection(snapshot):
            if let session = snapshot.session { candidate.session = session }
            reconcileOwner(snapshot.owner, source: envelope.source, in: &candidate)
            candidate.devices.localDeviceID = snapshot.localDeviceID
        case let .presentation(presentation):
            let incomingURI = playbackTrackURI(presentation.currentTrack?.uri)
            if !shouldHoldOptimisticPlayTarget(incomingURI: incomingURI, in: candidate) {
                supersedeOptimisticPlayTargetIfNeeded(incomingURI: incomingURI, in: &candidate)
                reconcileSeekTiming(
                    presentation.timing,
                    incomingTrackURI: presentation.currentTrack?.uri,
                    in: &candidate
                )
                candidate.currentTrack = presentation.currentTrack
                reconcileTransport(
                    presentation.transport,
                    incomingTrackURI: incomingURI,
                    in: &candidate
                )
            }
        case let .trackMetadata(metadata):
            guard var track = candidate.currentTrack, track.uri == metadata.uri else { return false }
            track.title = metadata.title
            track.artist = metadata.artist
            track.artworkURL = metadata.artworkURL
            track.duration = metadata.duration
            track.metadataSource = metadata.source
            candidate.currentTrack = track
            if metadata.duration > 0 {
                candidate.timing.duration = metadata.duration
            }
        case let .timing(position, duration, anchoredAt):
            reconcileSeekTiming(
                PlaybackTiming(
                    position: max(0, position),
                    duration: max(0, duration),
                    anchoredAt: anchoredAt
                ),
                incomingTrackURI: candidate.currentTrack?.uri,
                in: &candidate
            )
        case let .options(options):
            reconcileRepeat(
                flags: options.repeatFlags,
                mode: options.repeatMode,
                source: envelope.source,
                in: &candidate
            )
            reconcileShuffle(options.shuffle, source: envelope.source, in: &candidate)
        case let .queue(incoming):
            candidate.queue = mergePlaybackQueueSnapshots(
                current: candidate.queue,
                incoming: incoming
            )
        case let .devices(devices):
            guard devices.revision >= candidate.devices.revision else { return false }
            candidate.devices = devices
            applyConnectionPlaybackOwner(&candidate, source: envelope.source)
        case let .commandStarted(command):
            // Capture current presentation before applying the caller's target. The store must
            // not mutate transport, timing, track, shuffle, repeat, or owner first, or rollback
            // records the optimistic values. Do not clear other commands' resolutions: a later
            // pause must not recycle the already-reconciled-success path for a superseded play.
            let prepared = PendingPlaybackCommand(
                id: command.id,
                kind: command.kind,
                expectedTransport: command.expectedTransport,
                rollbackTransport: command.rollbackTransport
                    ?? (command.expectedTransport == nil && command.expectedTrack == nil ? nil : candidate.transport),
                expectedTiming: command.expectedTiming,
                rollbackTiming: command.rollbackTiming
                    ?? (command.expectedTiming == nil && command.expectedTrack == nil ? nil : candidate.timing),
                latestAuthoritativeTiming: nil,
                expectedTrack: command.expectedTrack,
                rollbackPresentation: command.rollbackPresentation
                    ?? (command.expectedTrack == nil
                        ? nil
                        : PlaybackPresentationSnapshot(
                            currentTrack: candidate.currentTrack,
                            transport: candidate.transport,
                            timing: candidate.timing
                        )),
                expectedShuffle: command.expectedShuffle,
                rollbackShuffle: command.rollbackShuffle
                    ?? (command.expectedShuffle == nil ? nil : candidate.options.shuffle),
                expectedRepeatFlags: command.expectedRepeatFlags,
                rollbackRepeatFlags: command.rollbackRepeatFlags
                    ?? (command.expectedRepeatFlags == nil ? nil : candidate.options.repeatFlags),
                expectedOwner: command.expectedOwner,
                rollbackOwner: command.rollbackOwner ?? (command.expectedOwner == nil ? nil : candidate.owner),
                startedAt: command.startedAt
            )
            candidate.pendingCommands[command.kind] = prepared
            if let expectedTrack = command.expectedTrack {
                if playbackTrackURI(candidate.currentTrack?.uri) != playbackTrackURI(expectedTrack.uri) {
                    candidate.pendingCommands[.seek] = nil
                }
                candidate.currentTrack = expectedTrack
            }
            if let expected = command.expectedTransport {
                candidate.transport = expected
            }
            if let expected = command.expectedTiming {
                candidate.timing = expected
            }
            if let expectedShuffle = command.expectedShuffle {
                candidate.options.shuffle = expectedShuffle
            }
            if let expectedRepeat = command.expectedRepeatFlags {
                applyRepeatFlags(expectedRepeat, to: &candidate)
            }
            if let expectedOwner = command.expectedOwner {
                candidate.owner = expectedOwner
            }
        case let .commandFinished(id, accepted, notice):
            if let pair = candidate.pendingCommands.first(where: { $0.value.id == id }) {
                candidate.pendingCommands[pair.key] = nil
                candidate.transportCommandResolutions[id] = nil
                if !accepted {
                    if let rollback = pair.value.rollbackPresentation {
                        candidate.pendingCommands[.seek] = nil
                        candidate.currentTrack = rollback.currentTrack
                        candidate.transport = rollback.transport
                        candidate.timing = rollback.timing
                    } else {
                        if let rollback = pair.value.rollbackTransport {
                            candidate.transport = rollback
                        }
                        if pair.key == .seek, let latest = pair.value.latestAuthoritativeTiming {
                            candidate.timing = latest
                        } else if let rollback = pair.value.rollbackTiming {
                            candidate.timing = rollback
                        }
                    }
                    if let rollbackShuffle = pair.value.rollbackShuffle {
                        candidate.options.shuffle = rollbackShuffle
                    }
                    if let rollbackRepeat = pair.value.rollbackRepeatFlags {
                        applyRepeatFlags(rollbackRepeat, to: &candidate)
                    }
                    if let rollbackOwner = pair.value.rollbackOwner {
                        candidate.owner = rollbackOwner
                    }
                    // A rejected finish with no notice restores rollback without replacing an
                    // unrelated existing notice. Cancellation is one caller of that rule.
                    if let notice {
                        candidate.notice = notice
                    }
                } else {
                    if let expectedShuffle = pair.value.expectedShuffle {
                        candidate.options.shuffle = expectedShuffle
                    }
                    if let expectedRepeat = pair.value.expectedRepeatFlags {
                        applyRepeatFlags(expectedRepeat, to: &candidate)
                    }
                }
            } else if candidate.transportCommandResolutions[id] != nil {
                // Consume a confirmed/superseded entry without touching presentation.
                candidate.transportCommandResolutions[id] = nil
            } else {
                return false
            }
        case let .notice(notice):
            candidate.notice = notice
        }

        // Record a revision only after the event itself was accepted. Reset creates a fresh
        // snapshot, so doing this last also preserves reset as a barrier against queued events.
        if let revision = envelope.revision {
            candidate.sourceRevisions[envelope.source] = revision
        }
        state = candidate
        return true
    }

    /// Account epoch, engine epoch, and per-source revision gates shared by `accepts` and `reduce`.
    /// The returned candidate has not yet recorded `envelope.revision`.
    private static func adopting(
        _ state: PlaybackState,
        accountEpoch: UInt64,
        engineEpoch: UInt64,
        source: PlaybackEventSource,
        revision: UInt64?
    ) -> PlaybackState? {
        var candidate = state

        guard accountEpoch >= candidate.accountEpoch else { return nil }
        if accountEpoch > candidate.accountEpoch {
            candidate = PlaybackState(
                accountEpoch: accountEpoch,
                engineEpoch: engineEpoch,
                session: .signedOut
            )
        }

        guard engineEpoch >= candidate.engineEpoch else { return nil }
        if engineEpoch > candidate.engineEpoch {
            candidate.engineEpoch = engineEpoch
            candidate.sourceRevisions = [:]
            candidate.pendingCommands = [:]
            candidate.transportCommandResolutions = [:]
            candidate.devices.revision = 0
        }

        if let revision {
            let previous = candidate.sourceRevisions[source] ?? 0
            guard revision > previous else { return nil }
        }

        return candidate
    }

    private static func reconcileTransport(
        _ transport: PlaybackTransportState,
        incomingTrackURI: String?,
        isTrackUnavailable: Bool = false,
        in state: inout PlaybackState
    ) {
        if let pending = state.pendingCommands[.transport],
            let targetURI = playbackTrackURI(pending.expectedTrack?.uri)
        {
            let incoming = playbackTrackURI(incomingTrackURI)
            if incoming != targetURI {
                state.transport = pending.expectedTransport ?? transport
                return
            }
            if let expected = pending.expectedTransport, transport != expected {
                // A failed target overrides optimistic transport until command completion.
                state.transport = isTrackUnavailable ? transport : expected
            } else {
                state.transport = transport
                if pending.expectedTransport == nil || pending.expectedTransport == transport {
                    state.transportCommandResolutions[pending.id] = .confirmed
                    state.pendingCommands[.transport] = nil
                }
            }
            return
        }
        if let pending = state.pendingCommands[.transport],
            let expected = pending.expectedTransport,
            transport != expected
        {
            state.transport = expected
        } else {
            state.transport = transport
            if state.pendingCommands[.transport]?.expectedTransport == transport {
                state.pendingCommands[.transport] = nil
            }
        }
    }

    /// Lagging snapshots of the pre-command track must not confirm or replace a known play target.
    private static func shouldHoldOptimisticPlayTarget(
        incomingURI: String?,
        in state: PlaybackState
    ) -> Bool {
        guard let pending = state.pendingCommands[.transport],
            let targetURI = playbackTrackURI(pending.expectedTrack?.uri)
        else { return false }
        let incoming = playbackTrackURI(incomingURI)
        let rollbackURI = playbackTrackURI(pending.rollbackPresentation?.currentTrack?.uri)
        return incoming != nil && incoming != targetURI && incoming == rollbackURI
    }

    private static func supersedeOptimisticPlayTargetIfNeeded(
        incomingURI: String?,
        in state: inout PlaybackState
    ) {
        guard let pending = state.pendingCommands[.transport],
            let targetURI = playbackTrackURI(pending.expectedTrack?.uri)
        else { return }
        let incoming = playbackTrackURI(incomingURI)
        let rollbackURI = playbackTrackURI(pending.rollbackPresentation?.currentTrack?.uri)
        if incoming == targetURI { return }
        if incoming != nil, incoming == rollbackURI { return }
        state.pendingCommands[.transport] = nil
        state.transportCommandResolutions[pending.id] = .superseded
    }

    private static func applyEnginePlaybackOptions(
        _ snapshot: EnginePlaybackSnapshot,
        in candidate: inout PlaybackState
    ) {
        reconcileShuffle(snapshot.shuffle, source: .enginePlayback, in: &candidate)
        if snapshot.repeatMode != nil || snapshot.repeatFlags != nil {
            let flags =
                snapshot.repeatFlags
                ?? snapshot.repeatMode?.flags
                ?? candidate.options.repeatFlags
            let mode =
                snapshot.repeatMode
                ?? RepeatMode(context: flags.context, track: flags.track)
            reconcileRepeat(flags: flags, mode: mode, source: .enginePlayback, in: &candidate)
        }
    }

    /// A lagging pre-command shuffle sample must not undo the pending target. Only an
    /// authoritative engine-playback sample matching the requested value confirms the command
    /// so a late coordinator failure cannot restore the prior Boolean. User/preference
    /// `.options` events, including setRepeat copies of the optimistic Boolean, hold the
    /// pending target and cannot record confirmation. Repeat options commands have no
    /// expected shuffle and keep current adoption.
    private static func reconcileShuffle(
        _ incoming: Bool?,
        source: PlaybackEventSource,
        in state: inout PlaybackState
    ) {
        guard let incoming else { return }
        guard let pending = state.pendingCommands[.options],
            let expected = pending.expectedShuffle
        else {
            state.options.shuffle = incoming
            return
        }
        if incoming == expected {
            state.options.shuffle = incoming
            if source == .enginePlayback {
                state.pendingCommands[.options] = nil
                state.transportCommandResolutions[pending.id] = .confirmed
            }
            return
        }
    }

    /// Repeat options optimism is reducer-owned. Matching authoritative engine flags confirm
    /// so a late coordinator failure cannot restore the prior pair. Exact prior flags are
    /// lagging and must not confirm or replace the target. The known two-step intermediate
    /// is applied for honest Connect/FFI sequencing but stays pending so compensation can
    /// still restore the captured previous pair. Unrelated authoritative flags supersede.
    /// User/preference `.options` events cannot confirm or supersede.
    private static func reconcileRepeat(
        flags: RepeatFlags,
        mode: RepeatMode,
        source: PlaybackEventSource,
        in state: inout PlaybackState
    ) {
        guard let pending = state.pendingCommands[.options],
            let expected = pending.expectedRepeatFlags
        else {
            state.options.repeatFlags = flags
            state.options.repeatMode = mode
            return
        }
        if flags == expected {
            applyRepeatFlags(expected, to: &state)
            if source == .enginePlayback {
                state.pendingCommands[.options] = nil
                state.transportCommandResolutions[pending.id] = .confirmed
            }
            return
        }
        if flags == pending.rollbackRepeatFlags {
            return
        }
        if let previous = pending.rollbackRepeatFlags,
            isRepeatTransitionIntermediate(previous: previous, target: expected, incoming: flags)
        {
            state.options.repeatFlags = flags
            state.options.repeatMode = mode
            return
        }
        if source == .enginePlayback {
            state.options.repeatFlags = flags
            state.options.repeatMode = mode
            state.pendingCommands[.options] = nil
            state.transportCommandResolutions[pending.id] = .superseded
        }
    }

    private static func isRepeatTransitionIntermediate(
        previous: RepeatFlags,
        target: RepeatFlags,
        incoming: RepeatFlags
    ) -> Bool {
        let plan = RepeatTransitionPlan.planning(from: previous, to: target)
        guard let first = plan.mutations.first, plan.mutations.count > 1 else { return false }
        return previous.applying(first) == incoming
    }

    private static func applyRepeatFlags(_ flags: RepeatFlags, to state: inout PlaybackState) {
        state.options.repeatFlags = flags
        state.options.repeatMode = RepeatMode(context: flags.context, track: flags.track)
    }

    /// A lagging snapshot of the pre-command owner must not undo a pending remote-transfer
    /// target. Identity is the stable device id, never name or type. An authoritative
    /// connection or devices snapshot whose identified local/remote owner matches the
    /// target confirms the command so a late coordinator failure cannot restore the
    /// prior owner. An unrelated identified owner, or a genuine empty owner that is
    /// not the exact prior emptiness, supersedes: rollback is cleared and a later
    /// finish stays inert. Uncertain copies of the target keep the pending command.
    private static func reconcileOwner(
        _ incoming: PlaybackOwner,
        source: PlaybackEventSource,
        in state: inout PlaybackState
    ) {
        guard let pending = state.pendingCommands[.transfer],
            let expected = pending.expectedOwner
        else {
            state.owner = incoming
            return
        }
        let expectedID = playbackOwnerStableDeviceID(expected)
        let incomingID = playbackOwnerStableDeviceID(incoming)
        let rollbackID = pending.rollbackOwner.flatMap(playbackOwnerStableDeviceID)
        if let expectedID, incomingID == expectedID {
            state.owner = incoming
            if isIdentifiedPlaybackOwner(incoming),
                source == .engineConnection || source == .engineDevices
            {
                state.pendingCommands[.transfer] = nil
                state.transportCommandResolutions[pending.id] = .confirmed
            }
            return
        }
        if incomingID == rollbackID {
            return
        }
        state.owner = incoming
        state.pendingCommands[.transfer] = nil
        state.transportCommandResolutions[pending.id] = .superseded
    }

    private static func playbackOwnerStableDeviceID(_ owner: PlaybackOwner) -> String? {
        let id: String?
        switch owner {
        case .none, .uncertain(nil):
            id = nil
        case let .local(device), let .remote(device), let .uncertain(.some(device)):
            id = device.id
        }
        return id.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func isIdentifiedPlaybackOwner(_ owner: PlaybackOwner) -> Bool {
        switch owner {
        case .local, .remote:
            return true
        case .none, .uncertain:
            return false
        }
    }

    /// Holds optimistic seek timing until an incoming sample is at the expected millisecond
    /// position on the same track. A different track or empty URI supersedes the old seek and
    /// adopts the incoming timing so rollback cannot attach the previous track's position.
    /// While the optimistic value is held, retain each accepted same-track authoritative engine
    /// sample for a rejected seek. Its `anchoredAt` remains the engine's original timestamp.
    /// `recordsAuthoritativeSample` is set only for atomic `.enginePlayback` snapshots. A
    /// `.timing` refresh is a separately awaited user-sourced getter result without track identity
    /// or a playback revision, so it must not become rollback evidence for this seek.
    private static func reconcileSeekTiming(
        _ timing: PlaybackTiming,
        incomingTrackURI: String?,
        recordsAuthoritativeSample: Bool = false,
        in state: inout PlaybackState
    ) {
        let incomingURI = playbackTrackURI(incomingTrackURI)
        if state.pendingCommands[.seek] != nil,
            incomingURI == nil || playbackTrackURI(state.currentTrack?.uri) != incomingURI
        {
            state.pendingCommands[.seek] = nil
            state.timing = timing
            return
        }
        if let pending = state.pendingCommands[.seek],
            let expected = pending.expectedTiming,
            !matchesExpectedSeekPosition(timing, expected)
        {
            if recordsAuthoritativeSample {
                var updated = pending
                updated.latestAuthoritativeTiming = timing
                state.pendingCommands[.seek] = updated
            }
            state.timing = expected
        } else {
            state.timing = timing
            if let pending = state.pendingCommands[.seek],
                let expected = pending.expectedTiming,
                matchesExpectedSeekPosition(timing, expected)
            {
                state.pendingCommands[.seek] = nil
            }
        }
    }

    private static func applyConnectionPlaybackOwner(
        _ candidate: inout PlaybackState,
        source: PlaybackEventSource
    ) {
        let devices = candidate.devices
        let isLocalActive = devices.devices.contains {
            $0.isActive && $0.id == devices.localDeviceID
        }
        reconcileOwner(
            connectionPlaybackOwner(
                isLocalActive: isLocalActive,
                localDeviceID: devices.localDeviceID,
                localDeviceName: devices.devices.first { $0.id == devices.localDeviceID }?.name ?? "",
                devices: devices.devices,
                currentTrackURI: candidate.currentTrack?.uri,
                previousOwner: candidate.owner,
                lastRemoteDeviceID: devices.lastRemoteDeviceID
            ),
            source: source,
            in: &candidate
        )
    }

    /// Cluster delivery notifies devices before player state, so the first no-active snapshot
    /// often has no URI yet and resolves to `.none`. When a URI later appears or clears, reuse
    /// the stamped last-remote context instead of leaving `.none` locally routable.
    /// Connection-authoritative `.local` / `.remote` / identified `.uncertain` owners stay put
    /// until a devices snapshot re-resolves them.
    private static func adoptOwnerAfterTrackURIChange(
        previousURI: String?,
        incomingURI: String?,
        source: PlaybackEventSource,
        in candidate: inout PlaybackState
    ) {
        let previous = playbackTrackURI(previousURI)
        let incoming = playbackTrackURI(incomingURI)
        guard previous != incoming else { return }
        if incoming == nil {
            if case .uncertain = candidate.owner {
                applyConnectionPlaybackOwner(&candidate, source: source)
            }
            return
        }
        guard previous == nil else { return }
        switch candidate.owner {
        case .none, .uncertain(nil):
            applyConnectionPlaybackOwner(&candidate, source: source)
        default:
            break
        }
    }

    private static func playbackTrackURI(_ uri: String?) -> String? {
        uri.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func matchesExpectedSeekPosition(
        _ actual: PlaybackTiming,
        _ expected: PlaybackTiming
    ) -> Bool {
        Int((actual.position * 1_000).rounded()) == Int((expected.position * 1_000).rounded())
    }

}
