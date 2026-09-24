import Testing
import SpottyDomain
import Foundation

// A model-based (property) check for `PlaybackReducer`. Randomized envelope traces are replayed
// against the pure reducer and every step is validated against invariants that hold for *every*
// event, accepted or rejected. Hand-enumerated interleavings stay in `PlaybackReducerChecks`;
// this file is the safety net for the interleavings nobody thought to write down.
//
// Determinism: every trace is generated from a SplitMix64 seed, so a reported `seed`/`step` pair
// reproduces the exact failing trace.

// MARK: - Deterministic PRNG

private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func nextInt(_ rng: inout SplitMix64, _ upperBound: Int) -> Int {
    Int.random(in: 0..<Swift.max(1, upperBound), using: &rng)
}

private func nextBool(_ rng: inout SplitMix64) -> Bool {
    Bool.random(using: &rng)
}

private func pick<Element>(_ values: [Element], _ rng: inout SplitMix64) -> Element {
    values[nextInt(&rng, values.count)]
}

private func makeUUID(_ rng: inout SplitMix64) -> UUID {
    let high = rng.next()
    let low = rng.next()
    func byte(_ value: UInt64, _ index: Int) -> UInt8 {
        UInt8(truncatingIfNeeded: value >> (8 * UInt64(index)))
    }
    return UUID(
        uuid: (
            byte(high, 0), byte(high, 1), byte(high, 2), byte(high, 3),
            byte(high, 4), byte(high, 5), byte(high, 6), byte(high, 7),
            byte(low, 0), byte(low, 1), byte(low, 2), byte(low, 3),
            byte(low, 4), byte(low, 5), byte(low, 6), byte(low, 7)
        )
    )
}

// MARK: - Generation universe

private let modelTrackURIs: [String] = [
    "spotify:track:alpha", "spotify:track:beta", "spotify:track:gamma", "",
]
private let modelLocalDeviceID = "device-local"
private let modelRemoteDeviceIDs: [String] = ["device-remote-1", "device-remote-2"]
private let modelDeviceIDs: [String] = [modelLocalDeviceID, "device-remote-1", "device-remote-2"]
private let modelTransports: [PlaybackTransportState] = [.stopped, .buffering, .paused, .playing]
private let modelCommandKinds: [PlaybackCommandKind] = [
    .transport, .navigation, .seek, .options, .transfer,
]
private let modelSessions: [PlaybackSessionPhase] = [
    .signedOut, .authorizing, .connecting, .ready, .recovering, .failed("synthetic"),
]
private let modelRepeatFlags: [RepeatFlags] = [
    RepeatFlags(context: false, track: false),
    RepeatFlags(context: true, track: false),
    RepeatFlags(context: false, track: true),
    RepeatFlags(context: true, track: true),
]
private let modelRepeatModes: [RepeatMode] = [.off, .context, .track]
private let modelQueueSources: [PlaybackQueueSource] = [.none, .provisional, .connect, .webAPI]
private let modelCompleteness: [PlaybackQueueCompleteness] = [.metadataOnly, .partial, .complete]
private let modelProvenance: [MetadataProvenance] = [.none, .catalog, .connect, .engine]

// MARK: - Envelope generator

private struct EnvelopeGenerator {
    var rng: SplitMix64
    var clock = Date(timeIntervalSince1970: 1_700_000_000)
    var revisions: [PlaybackEventSource: UInt64] = [:]
    var deviceRevision: UInt64 = 0
    var knownIDs: [UUID] = []
    let commandHeavy: Bool

    // MARK: Primitives

    private mutating func randomNotice() -> PlaybackNotice? {
        guard nextBool(&rng) else { return nil }
        return PlaybackNotice(
            message: "synthetic notice", kind: nextBool(&rng) ? .command : .resumeUnavailable)
    }

    private mutating func nextRevision(for source: PlaybackEventSource) -> UInt64 {
        let counter = (revisions[source] ?? 0) &+ 1
        revisions[source] = counter
        // Occasionally replay an older revision so the ordered-source gate is exercised.
        if counter > 2, nextInt(&rng, 5) == 0 {
            return counter - UInt64(1 + nextInt(&rng, 2))
        }
        return counter
    }

    private mutating func randomTiming() -> PlaybackTiming {
        PlaybackTiming(
            position: Double(nextInt(&rng, 300)),
            duration: nextBool(&rng) ? 0 : Double(200 + nextInt(&rng, 100)),
            anchoredAt: clock
        )
    }

    private mutating func randomDevice() -> PlaybackDevice {
        let id = pick(modelDeviceIDs, &rng)
        return PlaybackDevice(
            id: id,
            name: "Device \(id)",
            type: id == modelLocalDeviceID ? "computer" : "speaker",
            isActive: nextBool(&rng)
        )
    }

    private mutating func randomOwner() -> PlaybackOwner {
        switch nextInt(&rng, 5) {
        case 0: return .none
        case 1: return .local(randomDevice())
        case 2: return .remote(randomDevice())
        case 3: return .uncertain(nil)
        default: return .uncertain(randomDevice())
        }
    }

    private mutating func randomDeviceList() -> [PlaybackDevice] {
        let count = nextInt(&rng, 4)
        guard count > 0 else { return [] }
        let activeIndex = nextInt(&rng, count + 1)
        return (0..<count).map { index in
            let id = modelDeviceIDs[index % modelDeviceIDs.count]
            return PlaybackDevice(
                id: id,
                name: "Device \(id)",
                type: id == modelLocalDeviceID ? "computer" : "speaker",
                isActive: index == activeIndex
            )
        }
    }

    private mutating func randomDeviceSnapshot() -> PlaybackDeviceSnapshot {
        deviceRevision &+= 1
        let revision = nextInt(&rng, 5) == 0 && deviceRevision > 1 ? deviceRevision - 1 : deviceRevision
        return PlaybackDeviceSnapshot(
            devices: randomDeviceList(),
            localDeviceID: nextInt(&rng, 8) == 0 ? nil : modelLocalDeviceID,
            revision: revision,
            lastRemoteDeviceID: nextBool(&rng) ? pick(modelRemoteDeviceIDs, &rng) : nil
        )
    }

    private mutating func randomConnectionSnapshot() -> EngineConnectionSnapshot {
        EngineConnectionSnapshot(
            session: nextBool(&rng) ? pick(modelSessions, &rng) : nil,
            owner: randomOwner(),
            localDeviceID: nextInt(&rng, 8) == 0 ? nil : modelLocalDeviceID
        )
    }

    /// In command-heavy mode most engine samples echo the live expectations so the
    /// confirmation and supersession paths are actually reached.
    private mutating func randomPlaybackSnapshot(_ state: PlaybackState) -> EnginePlaybackSnapshot {
        if commandHeavy, nextInt(&rng, 10) < 7 {
            let transportPending = state.pendingCommands[.transport]
            let optionsPending = state.pendingCommands[.options]
            let seekPending = state.pendingCommands[.seek]
            let expectedURI: String? =
                transportPending.flatMap { $0.expectedTrack?.uri ?? $0.expectedTrackURI }
            let target: String? = expectedURI ?? state.currentTrack?.uri
            let expectedTransport: PlaybackTransportState? =
                transportPending.flatMap { $0.expectedTransport }
            let expectedTiming: PlaybackTiming? = seekPending.flatMap { $0.expectedTiming }
            let expectedShuffle: Bool? = optionsPending.flatMap { $0.expectedShuffle }
            let expectedRepeat: RepeatFlags? = optionsPending.flatMap { $0.expectedRepeatFlags }
            let fallbackShuffle: Bool? = nextBool(&rng) ? nextBool(&rng) : nil
            let recovery = transportPending?.recoveryTarget
            let context: String? =
                switch recovery?.selection {
                case let .context(uri): uri
                case .track: ""
                case nil: nextBool(&rng) ? pick(modelTrackURIs, &rng) : nil
                }
            return EnginePlaybackSnapshot(
                transport: expectedTransport ?? pick(modelTransports, &rng),
                trackURI: target,
                timing: recovery == nil
                    ? (expectedTiming ?? randomTiming()) : PlaybackTiming(position: 0, anchoredAt: clock),
                trackUnavailable: nextInt(&rng, 12) == 0,
                audioKeyRefused: nextBool(&rng),
                shuffle: expectedShuffle ?? fallbackShuffle,
                repeatMode: nil,
                repeatFlags: expectedRepeat,
                contextURI: context,
                isActiveDevice: recovery?.local ?? nextBool(&rng)
            )
        }
        return EnginePlaybackSnapshot(
            transport: pick(modelTransports, &rng),
            trackURI: nextInt(&rng, 6) == 0 ? nil : pick(modelTrackURIs, &rng),
            timing: randomTiming(),
            trackUnavailable: nextInt(&rng, 8) == 0,
            audioKeyRefused: nextInt(&rng, 3) == 0,
            shuffle: nextBool(&rng) ? nextBool(&rng) : nil,
            repeatMode: nextBool(&rng) ? pick(modelRepeatModes, &rng) : nil,
            repeatFlags: nextBool(&rng) ? pick(modelRepeatFlags, &rng) : nil,
            contextURI: nextBool(&rng) ? pick(modelTrackURIs, &rng) : nil,
            isActiveDevice: nextBool(&rng)
        )
    }

    private mutating func randomQueueSnapshot() -> PlaybackQueueSnapshot {
        let count = nextInt(&rng, 4)
        var entries: [PlaybackQueueItem] = []
        for index in 0..<count {
            let provider = nextBool(&rng) ? "connect" : "web-api"
            let uid = nextBool(&rng) ? "uid-\(index)" : ""
            entries.append(
                PlaybackQueueItem(
                    uri: modelTrackURIs[index % modelTrackURIs.count],
                    provider: provider,
                    occurrence: index,
                    uid: uid
                )
            )
        }
        return PlaybackQueueSnapshot(
            entries: entries,
            source: pick(modelQueueSources, &rng),
            completeness: pick(modelCompleteness, &rng),
            revision: UInt64(nextInt(&rng, 8)),
            receivedAt: clock,
            contextURI: nextBool(&rng) ? pick(modelTrackURIs, &rng) : nil
        )
    }

    private mutating func randomTrack() -> CurrentTrack {
        CurrentTrack(
            uri: pick(modelTrackURIs, &rng),
            title: nextBool(&rng) ? "Title" : nil,
            artist: nextBool(&rng) ? "Artist" : nil,
            artworkURL: nil,
            duration: Double(nextInt(&rng, 400)),
            metadataSource: pick(modelProvenance, &rng)
        )
    }

    // MARK: Command lifecycle

    private mutating func makeStartedCommand(_ state: PlaybackState) -> PendingPlaybackCommand {
        let kind = pick(modelCommandKinds, &rng)
        let id = makeUUID(&rng)
        var expectedTransport: PlaybackTransportState?
        var expectedTiming: PlaybackTiming?
        var expectedTrack: CurrentTrack?
        var expectedTrackURI: String?
        var resumeTarget: PlaybackResumeTarget?
        var recoveryTarget: PlaybackRecoveryTarget?
        var expectedShuffle: Bool?
        var expectedRepeatFlags: RepeatFlags?
        var expectedOwner: PlaybackOwner?
        switch kind {
        case .transport:
            expectedTransport = pick(modelTransports, &rng)
            if let current = state.currentTrack, !current.uri.isEmpty, nextInt(&rng, 3) == 0 {
                expectedTransport = .playing
                expectedTrackURI = current.uri
                expectedTiming = state.timing
                resumeTarget = PlaybackResumeTarget(
                    trackURI: current.uri, contextURI: state.playbackContextURI,
                    positionMS: UInt32(state.timing.position * 1_000), engineGeneration: state.engineEpoch)
            } else if nextBool(&rng) {
                expectedTrack = randomTrack()
            } else if nextBool(&rng) {
                expectedTrackURI = pick(modelTrackURIs, &rng)
            }
        case .seek:
            expectedTiming = randomTiming()
        case .options:
            if nextBool(&rng) {
                expectedShuffle = nextBool(&rng)
            } else {
                expectedRepeatFlags = pick(modelRepeatFlags, &rng)
            }
        case .transfer:
            // A nil expected owner is the transfer-to-this-Mac shape.
            expectedOwner = nextInt(&rng, 4) == 0 ? nil : .remote(randomDevice())
        case .navigation, .queue:
            break
        }
        if kind == .transport, resumeTarget == nil, state.blockedResumeTarget != nil,
            let uri = expectedTrack?.uri ?? expectedTrackURI, !uri.isEmpty
        {
            expectedTransport = .playing
            recoveryTarget = PlaybackRecoveryTarget(
                selection: nextBool(&rng) ? .track(uri) : .context("spotify:playlist:recovery"),
                engineGeneration: state.engineEpoch, local: true)
        }
        return PendingPlaybackCommand(
            id: id,
            kind: kind,
            expectedTransport: expectedTransport,
            expectedTiming: expectedTiming,
            expectedTrack: expectedTrack,
            expectedTrackURI: expectedTrackURI,
            resumeTarget: resumeTarget,
            recoveryTarget: recoveryTarget,
            expectedShuffle: expectedShuffle,
            expectedRepeatFlags: expectedRepeatFlags,
            expectedOwner: expectedOwner,
            startedAt: clock
        )
    }

    private mutating func referencedID(_ state: PlaybackState) -> UUID {
        if nextInt(&rng, 8) == 0 || knownIDs.isEmpty { return makeUUID(&rng) }
        if nextBool(&rng), !state.intents.isEmpty {
            return state.intents[nextInt(&rng, state.intents.count)].command.id
        }
        return knownIDs[nextInt(&rng, knownIDs.count)]
    }

    private mutating func remember(_ id: UUID) {
        knownIDs.append(id)
        if knownIDs.count > 24 { knownIDs.removeFirst(knownIDs.count - 24) }
    }

    private mutating func commandEvent(_ state: PlaybackState) -> PlaybackEvent {
        switch nextInt(&rng, 10) {
        case 0, 1, 2, 3:
            let command = makeStartedCommand(state)
            remember(command.id)
            return .commandStarted(command)
        case 4:
            let command = PendingPlaybackCommand(
                id: makeUUID(&rng),
                kind: .queue,
                expectedTransport: nil,
                startedAt: clock
            )
            remember(command.id)
            var intent = PlaybackIntent(command: command, baselineTrackURI: state.currentTrack?.uri)
            intent.queueContextURI = state.queue.contextURI
            intent.queueRevision = state.queue.revision
            if nextBool(&rng) {
                intent.queueMinimumCounts = [pick(modelTrackURIs, &rng): 1]
            } else {
                intent.removedQueueUIDs = ["uid-0"]
            }
            return .queueIntentStarted(intent)
        case 5:
            return .queueIntentFinished(id: referencedID(state), accepted: nextBool(&rng))
        case 6:
            let admitted = state.intents.filter { $0.outcome == .admitted }
            let id =
                admitted.isEmpty
                ? referencedID(state) : admitted[nextInt(&rng, admitted.count)].command.id
            return .commandDispatched(id: id, at: clock)
        case 7:
            return .commandTimedOut(id: referencedID(state))
        default:
            return .commandFinished(
                id: referencedID(state),
                accepted: nextBool(&rng),
                notice: randomNotice()
            )
        }
    }

    private mutating func observationEvent(_ state: PlaybackState) -> (PlaybackEvent, PlaybackEventSource) {
        switch nextInt(&rng, 24) {
        case 0:
            return (.reset(session: pick(modelSessions, &rng)), .account)
        case 1, 2:
            return (.session(pick(modelSessions, &rng)), .account)
        case 3, 4:
            return (.owner(randomOwner()), .engineConnection)
        case 5, 6, 7, 8, 9:
            return (.enginePlayback(randomPlaybackSnapshot(state)), .enginePlayback)
        case 10, 11:
            return (.engineConnection(randomConnectionSnapshot()), .engineConnection)
        case 12, 13:
            let snapshot = EngineConnectSnapshot(
                devices: randomDeviceSnapshot(),
                connection: nextBool(&rng) ? randomConnectionSnapshot() : nil,
                connectionRevision: nextBool(&rng) ? nextRevision(for: .engineConnection) : nil,
                playback: nextBool(&rng) ? randomPlaybackSnapshot(state) : nil,
                playbackRevision: nextBool(&rng) ? nextRevision(for: .enginePlayback) : nil
            )
            return (.engineCluster(snapshot), .engineCluster)
        case 14, 15:
            let track: CurrentTrack? = nextInt(&rng, 5) == 0 ? nil : randomTrack()
            return (
                .presentation(
                    PlaybackPresentationSnapshot(
                        currentTrack: track,
                        transport: pick(modelTransports, &rng),
                        timing: randomTiming()
                    )
                ), .user
            )
        case 16:
            return (
                .trackMetadata(
                    PlaybackTrackMetadata(
                        uri: state.currentTrack?.uri ?? pick(modelTrackURIs, &rng),
                        title: "Title",
                        artist: "Artist",
                        artworkURL: nil,
                        duration: Double(nextInt(&rng, 400)),
                        source: pick(modelProvenance, &rng)
                    )
                ), .metadata
            )
        case 17, 18:
            let timing = randomTiming()
            return (
                .timing(position: timing.position, duration: timing.duration, anchoredAt: clock), .user
            )
        case 19:
            let flags = pick(modelRepeatFlags, &rng)
            return (
                .options(
                    PlaybackOptions(
                        shuffle: nextBool(&rng),
                        repeatMode: RepeatMode(context: flags.context, track: flags.track),
                        repeatFlags: flags
                    )
                ), .user
            )
        case 20, 21:
            return (.queue(randomQueueSnapshot()), .engineQueue)
        case 22:
            return (.devices(randomDeviceSnapshot()), .engineDevices)
        default:
            return (
                .notice(randomNotice()), .user
            )
        }
    }

    // MARK: Envelope

    mutating func makeEnvelope(_ state: PlaybackState) -> PlaybackEventEnvelope {
        clock = clock.addingTimeInterval(Double(nextInt(&rng, 4)))

        let accountRoll = nextInt(&rng, 100)
        let accountEpoch: UInt64
        if accountRoll < 3 {
            accountEpoch = state.accountEpoch &+ 1
        } else if accountRoll < 9 {
            accountEpoch = state.accountEpoch == 0 ? 0 : state.accountEpoch - 1
        } else {
            accountEpoch = state.accountEpoch
        }

        let engineRoll = nextInt(&rng, 100)
        let engineEpoch: UInt64
        if engineRoll < 4 {
            engineEpoch = state.engineEpoch &+ 1
        } else if engineRoll < 10 {
            engineEpoch = state.engineEpoch == 0 ? 0 : state.engineEpoch - 1
        } else {
            engineEpoch = state.engineEpoch
        }

        let commandThreshold = commandHeavy ? 60 : 25
        let generated: (PlaybackEvent, PlaybackEventSource)
        if nextInt(&rng, 100) < commandThreshold {
            generated = (commandEvent(state), .command)
        } else {
            generated = observationEvent(state)
        }
        let event = generated.0
        let source = generated.1

        let carriesRevision: Bool
        switch source {
        case .enginePlayback, .engineConnection, .engineDevices, .engineQueue, .engineCluster,
            .account:
            carriesRevision = nextInt(&rng, 10) != 0
        default:
            carriesRevision = nextInt(&rng, 5) == 0
        }
        let revision: UInt64? = carriesRevision ? nextRevision(for: source) : nil

        return PlaybackEventEnvelope(
            accountEpoch: accountEpoch,
            engineEpoch: engineEpoch,
            source: source,
            revision: revision,
            receivedAt: clock,
            event: event
        )
    }
}

// MARK: - Event description

private func describe(_ event: PlaybackEvent) -> String {
    switch event {
    case .reset: return "reset"
    case .session: return "session"
    case .owner: return "owner"
    case .enginePlayback: return "enginePlayback"
    case .engineConnection: return "engineConnection"
    case .engineCluster: return "engineCluster"
    case .presentation: return "presentation"
    case .trackMetadata: return "trackMetadata"
    case .timing: return "timing"
    case .options: return "options"
    case .queue: return "queue"
    case .devices: return "devices"
    case let .commandStarted(command): return "commandStarted(\(command.kind), \(command.id))"
    case let .queueIntentStarted(intent): return "queueIntentStarted(\(intent.command.id))"
    case let .queueIntentFinished(id, accepted): return "queueIntentFinished(\(id), \(accepted))"
    case let .commandDispatched(id, _): return "commandDispatched(\(id))"
    case let .commandTimedOut(id): return "commandTimedOut(\(id))"
    case let .commandFinished(id, accepted, _): return "commandFinished(\(id), \(accepted))"
    case .notice: return "notice"
    }
}

// MARK: - Invariants

/// A rejected envelope must leave the state byte-identical: nothing may be half applied and no
/// source revision may be consumed by an event the reducer refused.
private func rejectionIsInert(
    pre: PlaybackState, post: PlaybackState, accepted: Bool
) -> String? {
    guard !accepted else { return nil }
    return post == pre ? nil : "rejected event mutated state"
}

/// The account epoch never moves backwards. The engine epoch never moves backwards either,
/// except when an account epoch change rebuilds the whole state for a new account.
private func epochMonotonicity(pre: PlaybackState, post: PlaybackState) -> String? {
    if post.accountEpoch < pre.accountEpoch {
        return "accountEpoch regressed \(pre.accountEpoch) -> \(post.accountEpoch)"
    }
    if post.accountEpoch == pre.accountEpoch, post.engineEpoch < pre.engineEpoch {
        return "engineEpoch regressed \(pre.engineEpoch) -> \(post.engineEpoch)"
    }
    return nil
}

/// An epoch change is a barrier: nothing that belonged to the previous generation survives it.
/// Only bookkeeping created by the very event that carried the new epoch may exist afterwards.
private func epochChangeWipesBookkeeping(
    pre: PlaybackState, post: PlaybackState, envelope: PlaybackEventEnvelope, accepted: Bool
) -> String? {
    guard accepted else { return nil }
    guard post.accountEpoch > pre.accountEpoch || post.engineEpoch > pre.engineEpoch else {
        return nil
    }
    if !post.transportCommandResolutions.isEmpty {
        return "epoch change kept transportCommandResolutions"
    }
    var priorIDs = Set(pre.intents.map(\.command.id))
    priorIDs.formUnion(pre.pendingCommands.values.map(\.id))
    if post.intents.contains(where: { priorIDs.contains($0.command.id) }) {
        return "epoch change kept a previous-generation intent"
    }
    if post.pendingCommands.values.contains(where: { priorIDs.contains($0.id) }) {
        return "epoch change kept a previous-generation pending command"
    }
    if post.intents.count > 1 {
        return "epoch change left \(post.intents.count) intents"
    }
    var allowed: Set<PlaybackEventSource> = [envelope.source]
    if case .engineCluster = envelope.event {
        allowed.formUnion([.engineDevices, .enginePlayback, .engineConnection])
    }
    if !Set(post.sourceRevisions.keys).isSubset(of: allowed) {
        return "epoch change kept source revisions \(post.sourceRevisions.keys.sorted { "\($0)" < "\($1)" })"
    }
    return nil
}

/// Within one epoch pair, a per-source revision only moves forward. A reset deliberately clears
/// the table, so it is the one event excluded here.
private func revisionMonotonicity(
    pre: PlaybackState, post: PlaybackState, envelope: PlaybackEventEnvelope
) -> String? {
    guard post.accountEpoch == pre.accountEpoch, post.engineEpoch == pre.engineEpoch else {
        return nil
    }
    if case .reset = envelope.event { return nil }
    for (source, revision) in pre.sourceRevisions {
        guard let updated = post.sourceRevisions[source] else {
            return "source \(source) lost its recorded revision"
        }
        if updated < revision {
            return "source \(source) revision regressed \(revision) -> \(updated)"
        }
    }
    return nil
}

/// An accepted envelope carrying a revision must strictly advance its source, and the accepted
/// revision must be the one recorded.
private func revisionGate(
    pre: PlaybackState, post: PlaybackState, envelope: PlaybackEventEnvelope, accepted: Bool
) -> String? {
    guard accepted, let revision = envelope.revision else { return nil }
    guard post.accountEpoch == pre.accountEpoch, post.engineEpoch == pre.engineEpoch else {
        return nil
    }
    let previous = pre.sourceRevisions[envelope.source] ?? 0
    if revision <= previous {
        return "accepted revision \(revision) did not advance \(envelope.source) past \(previous)"
    }
    if post.sourceRevisions[envelope.source] != revision {
        return "accepted revision \(revision) was not recorded for \(envelope.source)"
    }
    return nil
}

/// Terminal intent outcomes are immutable. A later observation may still update playback truth
/// but can never re-open or rewrite a settled request.
private func terminalOutcomesAreImmutable(pre: PlaybackState, post: PlaybackState) -> String? {
    guard !pre.intents.isEmpty else { return nil }
    var settled: [UUID: PlaybackIntentOutcome] = [:]
    for intent in pre.intents where intent.outcome.isTerminal {
        settled[intent.command.id] = intent.outcome
    }
    guard !settled.isEmpty else { return nil }
    for intent in post.intents {
        guard let previous = settled[intent.command.id] else { continue }
        if intent.outcome != previous {
            return "terminal outcome \(previous) for \(intent.command.id) became \(intent.outcome)"
        }
    }
    return nil
}

/// The pending table is keyed by kind, so at most one command per kind can be in flight. Its
/// entries must agree with their key and with the intent record of the same id, and a timed-out
/// intent must never keep an entry there.
private func pendingCoherence(_ state: PlaybackState) -> String? {
    var seen: Set<UUID> = []
    for (kind, command) in state.pendingCommands {
        if command.kind != kind {
            return "pendingCommands[\(kind)] holds a \(command.kind) command"
        }
        if !seen.insert(command.id).inserted {
            return "command \(command.id) is pending under more than one kind"
        }
        guard let intent = state.intents.first(where: { $0.command.id == command.id }) else {
            continue
        }
        if intent.command.kind != kind {
            return "intent for pending \(kind) records kind \(intent.command.kind)"
        }
        if intent.outcome == .timedOut {
            return "timed-out intent \(command.id) is still pending"
        }
    }
    return nil
}

/// The retained history keeps the latest 128 records plus any still-active request.
private func intentHistoryWindow(
    pre: PlaybackState, post: PlaybackState, envelope: PlaybackEventEnvelope, accepted: Bool
) -> String? {
    guard accepted, pre.accountEpoch == post.accountEpoch, pre.engineEpoch == post.engineEpoch else { return nil }
    if case .reset = envelope.event { return nil }
    var admissions = pre.intents.map(\.command.id)
    switch envelope.event {
    case let .commandStarted(command): admissions.append(command.id)
    case let .queueIntentStarted(intent): admissions.append(intent.command.id)
    default: break
    }
    let recent = Set(admissions.suffix(128))
    let retained = Set(post.intents.map(\.command.id))
    if !recent.isSubset(of: retained) { return "retired an intent inside the latest 128 admissions" }
    if post.intents.contains(where: { !recent.contains($0.command.id) && $0.outcome.isTerminal }) {
        return "retained a settled intent outside the latest 128 admissions"
    }
    return nil
}

/// The reducer never publishes negative presentation timing.
private func timingIsNonNegative(_ state: PlaybackState) -> String? {
    if state.timing.position < 0 { return "negative position \(state.timing.position)" }
    if state.timing.duration < 0 { return "negative duration \(state.timing.duration)" }
    return nil
}

/// `accepts` is the query-only form of the same epoch/revision gate `reduce` applies, so a gate
/// refusal must always imply a reduction refusal.
private func gateAgreement(gateAllows: Bool, accepted: Bool) -> String? {
    if !gateAllows, accepted { return "accepts refused an envelope that reduce accepted" }
    return nil
}

/// `commandStarted` must capture rollback from the pre-command presentation, before the
/// optimistic target is applied. Otherwise rollback restores the optimistic values.
private func rollbackCapture(
    pre: PlaybackState, post: PlaybackState, envelope: PlaybackEventEnvelope, accepted: Bool
) -> String? {
    guard accepted, case let .commandStarted(command) = envelope.event else { return nil }
    guard post.accountEpoch == pre.accountEpoch, post.engineEpoch == pre.engineEpoch else {
        return nil
    }
    guard let stored = post.pendingCommands[command.kind], stored.id == command.id else {
        return nil
    }
    if command.expectedTransport != nil || command.expectedTrack != nil {
        if stored.rollbackTransport != pre.transport {
            return "rollbackTransport captured \(String(describing: stored.rollbackTransport)) not \(pre.transport)"
        }
    }
    if command.expectedTiming != nil || command.expectedTrack != nil {
        if stored.rollbackTiming != pre.timing {
            return "rollbackTiming did not capture the pre-command timing"
        }
    }
    if command.expectedTrack != nil {
        let expected = PlaybackPresentationSnapshot(
            currentTrack: pre.currentTrack,
            transport: pre.transport,
            timing: pre.timing
        )
        if stored.rollbackPresentation != expected {
            return "rollbackPresentation did not capture the pre-command presentation"
        }
    }
    if command.expectedShuffle != nil, stored.rollbackShuffle != pre.options.shuffle {
        return "rollbackShuffle did not capture the pre-command shuffle"
    }
    if command.expectedRepeatFlags != nil, stored.rollbackRepeatFlags != pre.options.repeatFlags {
        return "rollbackRepeatFlags did not capture the pre-command repeat flags"
    }
    if command.expectedOwner != nil, stored.rollbackOwner != pre.owner {
        return "rollbackOwner did not capture the pre-command owner"
    }
    return nil
}

/// A rejected finish for an undispatched pending command restores exactly the fields that
/// command claimed, to the values captured when it started. `captured` holds the state observed
/// immediately before the accepted `commandStarted`, so this is a cross-step check rather than a
/// restatement of the rollback record.
private func rollbackRestoration(
    pre: PlaybackState,
    post: PlaybackState,
    envelope: PlaybackEventEnvelope,
    accepted: Bool,
    captured: [UUID: PlaybackState]
) -> String? {
    guard accepted, case let .commandFinished(id, commandAccepted, _) = envelope.event,
        !commandAccepted
    else { return nil }
    guard post.accountEpoch == pre.accountEpoch, post.engineEpoch == pre.engineEpoch else {
        return nil
    }
    guard let command = pre.pendingCommands.first(where: { $0.value.id == id })?.value else {
        return nil
    }
    if let intent = pre.intents.first(where: { $0.command.id == id }), intent.dispatchedAt != nil {
        return nil
    }
    guard let origin = captured[id] else { return nil }

    if command.rollbackPresentation != nil {
        let expected = PlaybackPresentationSnapshot(
            currentTrack: origin.currentTrack,
            transport: origin.transport,
            timing: origin.timing
        )
        if post.currentTrack != expected.currentTrack {
            return "rollback did not restore the pre-command track"
        }
        if post.transport != expected.transport {
            return "rollback restored transport \(post.transport) not \(expected.transport)"
        }
        if post.timing != expected.timing {
            return "rollback did not restore the pre-command timing"
        }
    } else {
        if command.rollbackTransport != nil, post.transport != origin.transport {
            return "rollback restored transport \(post.transport) not \(origin.transport)"
        }
        // A held seek restores the newest same-track authoritative sample instead.
        if command.rollbackTiming != nil, command.latestAuthoritativeTiming == nil,
            post.timing != origin.timing
        {
            return "rollback did not restore the pre-command timing"
        }
    }
    if command.rollbackShuffle != nil, post.options.shuffle != origin.options.shuffle {
        return "rollback did not restore the pre-command shuffle"
    }
    if command.rollbackRepeatFlags != nil, post.options.repeatFlags != origin.options.repeatFlags {
        return "rollback did not restore the pre-command repeat flags"
    }
    if command.rollbackOwner != nil, post.owner != origin.owner {
        return "rollback did not restore the pre-command owner"
    }
    return nil
}

// MARK: - Trace runner

private func emptyResumeObservationPreservesIdentity(
    pre: PlaybackState, post: PlaybackState, envelope: PlaybackEventEnvelope, accepted: Bool
) -> String? {
    guard accepted, pre.accountEpoch == post.accountEpoch, pre.engineEpoch == post.engineEpoch,
        pre.pendingCommands[.transport]?.resumeTarget != nil,
        case let .enginePlayback(snapshot) = envelope.event,
        snapshot.trackURI?.isEmpty != false
    else { return nil }
    if pre.currentTrack != post.currentTrack || pre.playbackContextURI != post.playbackContextURI
        || pre.timing != post.timing || pre.options != post.options
    {
        return "an empty activation observation erased a pending resume's identity or position"
    }
    return nil
}

private func resumeBlockRequiresObservedRecovery(
    pre: PlaybackState, post: PlaybackState, envelope: PlaybackEventEnvelope
) -> String? {
    guard pre.accountEpoch == post.accountEpoch, pre.blockedResumeTarget != nil,
        post.blockedResumeTarget == nil
    else { return nil }
    if case .reset(.signedOut) = envelope.event { return nil }
    let confirmedRecovery = post.intents.contains { intent in
        intent.command.recoveryTarget != nil && intent.outcome == .observedConfirmed
            && pre.intents.first(where: { $0.command.id == intent.command.id })?.outcome != .observedConfirmed
    }
    return confirmedRecovery ? nil : "resume block cleared without a newly observed recovery target"
}

private func resumeConfirmationRequiresContext(
    pre: PlaybackState, post: PlaybackState, envelope: PlaybackEventEnvelope
) -> String? {
    guard case let .enginePlayback(snapshot) = envelope.event,
        snapshot.contextURI == nil || !snapshot.isActiveDevice
    else { return nil }
    for intent in post.intents where intent.command.resumeTarget != nil && intent.outcome == .observedConfirmed {
        if pre.intents.first(where: { $0.command.id == intent.command.id })?.outcome != .observedConfirmed {
            return "a sample without protocol context and active ownership confirmed a resume"
        }
    }
    return nil
}

private func firstViolation(
    pre: PlaybackState,
    post: PlaybackState,
    envelope: PlaybackEventEnvelope,
    accepted: Bool,
    gateAllows: Bool,
    captured: [UUID: PlaybackState]
) -> String? {
    if let violation = rejectionIsInert(pre: pre, post: post, accepted: accepted) {
        return violation
    }
    if let violation = epochMonotonicity(pre: pre, post: post) { return violation }
    if let violation = epochChangeWipesBookkeeping(
        pre: pre, post: post, envelope: envelope, accepted: accepted)
    {
        return violation
    }
    if let violation = revisionMonotonicity(pre: pre, post: post, envelope: envelope) {
        return violation
    }
    if let violation = revisionGate(
        pre: pre, post: post, envelope: envelope, accepted: accepted)
    {
        return violation
    }
    if let violation = terminalOutcomesAreImmutable(pre: pre, post: post) { return violation }
    if let violation = emptyResumeObservationPreservesIdentity(
        pre: pre, post: post, envelope: envelope, accepted: accepted)
    {
        return violation
    }
    if let violation = resumeBlockRequiresObservedRecovery(pre: pre, post: post, envelope: envelope) {
        return violation
    }
    if let violation = resumeConfirmationRequiresContext(pre: pre, post: post, envelope: envelope) {
        return violation
    }
    if let violation = pendingCoherence(post) { return violation }
    if let violation = intentHistoryWindow(pre: pre, post: post, envelope: envelope, accepted: accepted) {
        return violation
    }
    if let violation = timingIsNonNegative(post) { return violation }
    if let violation = gateAgreement(gateAllows: gateAllows, accepted: accepted) {
        return violation
    }
    if let violation = rollbackCapture(
        pre: pre, post: post, envelope: envelope, accepted: accepted)
    {
        return violation
    }
    return rollbackRestoration(
        pre: pre, post: post, envelope: envelope, accepted: accepted, captured: captured)
}

private func runModelTrace(seed: UInt64, steps: Int, commandHeavy: Bool) -> String? {
    var generator = EnvelopeGenerator(rng: SplitMix64(seed: seed), commandHeavy: commandHeavy)
    var state = PlaybackState(accountEpoch: 1, engineEpoch: 1, session: .ready)
    var captured: [UUID: PlaybackState] = [:]

    for step in 0..<steps {
        let envelope = generator.makeEnvelope(state)
        let pre = state
        let gateAllows = PlaybackReducer.accepts(
            pre,
            accountEpoch: envelope.accountEpoch,
            engineEpoch: envelope.engineEpoch,
            source: envelope.source,
            revision: envelope.revision
        )
        let reduction = PlaybackReducer.apply(&state, envelope: envelope)
        let accepted = reduction.accepted
        let post = state
        let enteredPlaying = accepted && pre.transport != .playing && post.transport == .playing
        if reduction.transportBecamePlaying != enteredPlaying {
            return "seed \(seed) step \(step) \(describe(envelope.event)): incorrect playing-transition report"
        }

        if let violation = firstViolation(
            pre: pre,
            post: post,
            envelope: envelope,
            accepted: accepted,
            gateAllows: gateAllows,
            captured: captured
        ) {
            return """
                seed \(seed) step \(step) \(describe(envelope.event)) \
                source \(envelope.source) revision \(String(describing: envelope.revision)) \
                epochs \(envelope.accountEpoch)/\(envelope.engineEpoch) accepted \(accepted): \
                \(violation)
                """
        }

        // Model bookkeeping: remember the presentation a command was started against, and drop
        // it once the command can no longer roll back.
        if accepted {
            switch envelope.event {
            case let .commandStarted(command):
                if post.accountEpoch == pre.accountEpoch, post.engineEpoch == pre.engineEpoch {
                    captured[command.id] = pre
                }
            case let .commandFinished(id, _, _):
                captured[id] = nil
            case let .commandTimedOut(id):
                captured[id] = nil
            default:
                break
            }
            if post.accountEpoch != pre.accountEpoch || post.engineEpoch != pre.engineEpoch {
                captured.removeAll()
            }
        }
    }
    return nil
}

// MARK: - Checks

@Suite("Playback Reducer Model")
struct PlaybackReducerModelChecks {
    @Test(arguments: [false, true])
    func historyKeepsRecentAdmissionsAlongsideOlderActiveRequests(queueCommands: Bool) {
        var state = PlaybackState(accountEpoch: 1, engineEpoch: 1, session: .ready)
        var rng = SplitMix64(seed: 128)
        let now = Date(timeIntervalSince1970: 100)
        var revision: UInt64 = 0
        func apply(_ event: PlaybackEvent) -> PlaybackReduction {
            revision += 1
            let envelope = PlaybackEventEnvelope(
                accountEpoch: 1, engineEpoch: 1, source: .command, revision: revision,
                receivedAt: now, event: event)
            let pre = state
            let reduction = PlaybackReducer.apply(&state, envelope: envelope)
            #expect(reduction.accepted)
            #expect(intentHistoryWindow(pre: pre, post: state, envelope: envelope, accepted: reduction.accepted) == nil)
            return reduction
        }
        let older = PendingPlaybackCommand(id: makeUUID(&rng), kind: .queue, expectedTransport: nil, startedAt: now)
        _ = apply(.queueIntentStarted(PlaybackIntent(command: older, baselineTrackURI: nil)))
        var recent: [UUID] = []
        for _ in 0..<128 {
            let command = PendingPlaybackCommand(
                id: makeUUID(&rng), kind: queueCommands ? .queue : .options, expectedTransport: nil, startedAt: now)
            recent.append(command.id)
            if queueCommands {
                _ = apply(.queueIntentStarted(PlaybackIntent(command: command, baselineTrackURI: nil)))
                _ = apply(.queueIntentFinished(id: command.id, accepted: false))
            } else {
                _ = apply(.commandStarted(command))
                _ = apply(.commandFinished(id: command.id, accepted: false, notice: nil))
            }
        }
        #expect(state.intents.map(\.command.id) == [older.id] + recent)
        #expect(state.intents.first?.outcome == .admitted)
        let reduction = apply(.queueIntentFinished(id: older.id, accepted: false))
        #expect(reduction.settledIntents == [SettledIntent(id: older.id, outcome: .rejected)])
        #expect(state.intents.map(\.command.id) == recent)
    }

    @Test(arguments: [false, true])
    func retiringObservedPlayKeepsSettlementAndHistoryReceipts(clustered: Bool) {
        var state = PlaybackState(accountEpoch: 1, engineEpoch: 1, session: .ready)
        var rng = SplitMix64(seed: 129)
        let now = Date(timeIntervalSince1970: 100)
        let track = "spotify:track:retained-play"
        func apply(_ event: PlaybackEvent, source: PlaybackEventSource = .command) -> PlaybackReduction {
            PlaybackReducer.apply(
                &state,
                envelope: PlaybackEventEnvelope(
                    accountEpoch: 1, engineEpoch: 1, source: source, receivedAt: now, event: event))
        }
        let play = PendingPlaybackCommand(
            id: makeUUID(&rng), kind: .transport, expectedTransport: .playing,
            expectedTrackURI: track, startedAt: now)
        #expect(apply(.commandStarted(play)).accepted)
        #expect(apply(.commandDispatched(id: play.id, at: now)).accepted)
        #expect(apply(.commandFinished(id: play.id, accepted: true, notice: nil)).accepted)
        for _ in 0..<128 {
            let command = PendingPlaybackCommand(
                id: makeUUID(&rng), kind: .queue, expectedTransport: nil, startedAt: now)
            #expect(apply(.queueIntentStarted(PlaybackIntent(command: command, baselineTrackURI: nil))).accepted)
            #expect(apply(.queueIntentFinished(id: command.id, accepted: false)).accepted)
        }
        let playback = EnginePlaybackSnapshot(
            transport: .playing, trackURI: track, timing: PlaybackTiming(anchoredAt: now))
        let reduction: PlaybackReduction
        if clustered {
            reduction = apply(
                .engineCluster(
                    EngineConnectSnapshot(
                        devices: state.devices, connection: nil, connectionRevision: nil,
                        playback: playback, playbackRevision: 1)),
                source: .engineCluster)
        } else {
            reduction = apply(.enginePlayback(playback), source: .enginePlayback)
        }
        #expect(
            reduction.settledIntents == [SettledIntent(id: play.id, outcome: .observedConfirmed, dispatchedAt: now)])
        #expect(reduction.confirmedPlayTrackURIs == [track])
        #expect(state.intents.count == 128)
        #expect(!state.intents.contains(where: { $0.command.id == play.id }))
    }

    @Test(arguments: [false, true], [false, true])
    func recoveryTraceReachesObservedSuccess(local: Bool, contextSelection: Bool) {
        let now = Date(timeIntervalSince1970: 100)
        let resume = UUID(), cancelled = UUID(), recovery = UUID()
        let track = "spotify:track:recovery"
        let context = "spotify:playlist:recovery"
        var state = PlaybackState(
            accountEpoch: 1, engineEpoch: 1, session: .ready,
            transport: .paused, currentTrack: CurrentTrack(uri: track), playbackContextURI: context,
            timing: PlaybackTiming(position: 152, anchoredAt: now))
        let target = PlaybackRecoveryTarget(
            selection: contextSelection ? .context(context) : .track(track),
            engineGeneration: 1, local: local)
        func load(_ id: UUID) -> PlaybackEvent {
            .commandStarted(
                PendingPlaybackCommand(
                    id: id, kind: .transport, expectedTransport: .playing,
                    expectedTrackURI: contextSelection ? nil : track, recoveryTarget: target, startedAt: now))
        }
        func snapshot(position: Double, context: String?, active: Bool) -> PlaybackEvent {
            .enginePlayback(
                EnginePlaybackSnapshot(
                    transport: .playing, trackURI: track,
                    timing: PlaybackTiming(position: position, anchoredAt: now), contextURI: context,
                    isActiveDevice: active))
        }
        let events: [(PlaybackEventSource, PlaybackEvent)] = [
            (
                .command,
                .commandStarted(
                    PendingPlaybackCommand(
                        id: resume, kind: .transport, expectedTransport: .playing,
                        expectedTrackURI: track,
                        resumeTarget: PlaybackResumeTarget(
                            trackURI: track, contextURI: context,
                            positionMS: 152_000, engineGeneration: 1), startedAt: now))
            ),
            (.command, .commandDispatched(id: resume, at: now)),
            (
                .command,
                .commandFinished(
                    id: resume, accepted: false,
                    notice: PlaybackNotice(message: "refused", kind: .resumeUnavailable))
            ),
            (.user, .notice(nil)),
            (.user, .notice(PlaybackNotice(message: "replacement message"))),
            (.command, load(cancelled)),
            (.command, .commandFinished(id: cancelled, accepted: false, notice: nil)),
            (.command, load(recovery)),
            (.command, .commandDispatched(id: recovery, at: now)),
            (.command, .commandFinished(id: recovery, accepted: true, notice: nil)),
            (.enginePlayback, snapshot(position: 0, context: nil, active: local)),
            (.enginePlayback, snapshot(position: 152, context: context, active: local)),
            (.enginePlayback, snapshot(position: 0, context: context, active: !local)),
            (.enginePlayback, snapshot(position: 0, context: context, active: local)),
        ]
        for (index, entry) in events.enumerated() {
            let envelope = PlaybackEventEnvelope(
                accountEpoch: 1, engineEpoch: 1, source: entry.0,
                revision: UInt64(index + 1), receivedAt: now, event: entry.1)
            let pre = state
            #expect(PlaybackReducer.reduce(&state, envelope: envelope))
            #expect(resumeBlockRequiresObservedRecovery(pre: pre, post: state, envelope: envelope) == nil)
            if index >= 2 && index < events.count - 1 {
                #expect(state.blockedResumeTarget != nil, "step \(index) cannot restore resume")
            }
            if index >= 7 && index < events.count - 1 {
                #expect(state.pendingCommands[.transport]?.id == recovery, "unmatched evidence cannot settle recovery")
            }
        }
        #expect(state.blockedResumeTarget == nil)
        #expect(state.intents.last?.outcome == .observedConfirmed)
        #expect(state.intents.first(where: { $0.command.id == cancelled })?.outcome == .rejected)
        #expect(state.notice?.message == "replacement message", "recovery does not dismiss an unrelated notice")
    }

    /// Broad coverage: every event case, stale and advancing epochs, replayed revisions.
    @Test
    func reducerHoldsInvariantsUnderRandomTraces() {
        for seed in UInt64(1)...UInt64(64) {
            if let violation = runModelTrace(seed: seed, steps: 120, commandHeavy: false) {
                Issue.record("\(violation)")
                return
            }
        }
    }

    /// Command-weighted coverage: most events are command lifecycle events and most engine
    /// samples echo the live expectations, so confirmation, supersession, and rollback paths
    /// are exercised rather than merely reachable.
    @Test
    func reducerHoldsInvariantsUnderCommandHeavyTraces() {
        for seed in UInt64(1_001)...UInt64(1_064) {
            if let violation = runModelTrace(seed: seed, steps: 120, commandHeavy: true) {
                Issue.record("\(violation)")
                return
            }
        }
    }
}
