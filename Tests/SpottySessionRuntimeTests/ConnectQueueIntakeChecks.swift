import SpottyDomain
import SpottyEngineAdapter
import SpottyRuntimeContracts
import SpottyTestSupport
import Testing
@testable import SpottyRuntimeTestSupport
@testable import SpottySessionRuntime

private func intakeEnvelope(
    sequence: UInt64 = 1, revision: UInt64 = 1, generation: UInt64,
    duplicates: Bool = false
) -> RustPlaybackEventEnvelope {
    var next = [QueueProtocolTrack(uri: "spotify:track:dup", uid: "q0", provider: "queue")]
    if duplicates { next.append(QueueProtocolTrack(uri: "spotify:track:dup", uid: "q1", provider: "queue")) }
    next += [
        QueueProtocolTrack(uri: "spotify:track:other", uid: "q2", provider: "queue"),
        QueueProtocolTrack(uri: "spotify:delimiter", uid: "", provider: "delimiter"),
        QueueProtocolTrack(uri: "spotify:track:autoplay", uid: "a0", provider: "autoplay"),
    ]
    return RustPlaybackEventEnvelope(
        sequence: sequence, receivedAt: HarnessDates.fixed,
        event: .queue(
            HarnessFixtures.queueState(
                revision: revision, generation: generation, trackURI: "spotify:track:now", next: next,
                prev: [QueueProtocolTrack(uri: "spotify:track:prev", uid: "p0", provider: "context")],
                queueRevision: "rev-\(revision)")))
}

@SessionRuntimeActor
private final class QueueIntakeFixture {
    struct Intake {
        let acceptance: PlaybackEffectSettlement
        let metadata: PlaybackEffectSettlement?
        func wait() async {
            await acceptance.wait()
            await metadata?.wait()
        }
    }

    let engine = HarnessEngine()
    let remote = HarnessRemote()
    let runtime: PlaybackSessionRuntime
    private var intakes: [Intake] = []

    init(hook: (any QueueServiceHook)?) {
        runtime = PlaybackSessionRuntime(
            environment: HarnessEnvironment.make(engine: engine, remote: remote, queueServiceHook: hook))
    }

    /// Both workers register synchronously at the real entrance. Earlier intake must be settled,
    /// so an accidentally rejected callback cannot borrow an older registration.
    func receive(_ envelope: RustPlaybackEventEnvelope) throws -> Intake {
        try #require(runtime.effects.settlement(of: .connectQueueAccept) == nil)
        try #require(runtime.effects.settlement(of: .trackMetadata) == nil)
        runtime.receive(envelope)
        let intake = Intake(
            acceptance: try #require(runtime.effects.settlement(of: .connectQueueAccept)),
            metadata: runtime.effects.settlement(of: .trackMetadata))
        intakes.append(intake)
        return intake
    }

    func cleanUp(closing: () -> Void) async {
        let cancelled = runtime.effects.cancelAccountScoped()
        closing()
        for intake in intakes { await intake.wait() }
        for settlement in cancelled.values { await settlement.wait() }
        await runtime.shutdownForTermination()
    }
}

@SessionRuntimeActor
private func withQueueIntake(
    hook: (any QueueServiceHook)? = nil, closing: () -> Void = {},
    _ body: (QueueIntakeFixture) async throws -> Void
) async throws {
    let fixture = QueueIntakeFixture(hook: hook)
    let runtime = fixture.runtime
    do {
        try #require(runtime.send(.session(.ready), source: .account))
        try #require(
            runtime.send(
                .devices(
                    PlaybackDeviceSnapshot(
                        devices: [
                            PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: false),
                            PlaybackDevice(id: "speaker", name: "Speaker", type: "speaker", isActive: true),
                        ], localDeviceID: "mac", revision: 1)), source: .engineDevices, revision: 1))
        await runtime.queueService.reset(accountEpoch: runtime.accountEpoch)
        try await body(fixture)
    } catch {
        await fixture.cleanUp(closing: closing)
        throw error
    }
    await fixture.cleanUp(closing: closing)
}

@Suite("Connect queue intake")
@SessionRuntimeActor
struct ConnectQueueIntakeTests {
    @Test func webEnrichmentPreservesConnectAuthorityAndCallbackWatermark() async throws {
        try await withQueueIntake { fixture in
            let runtime = fixture.runtime
            let intake = try fixture.receive(
                intakeEnvelope(revision: 4, generation: runtime.engineGeneration, duplicates: true))
            await intake.wait()
            let before = runtime.queueNextEntries
            let mutation = try #require(runtime.queueMutation)
            let watermark = runtime.connectQueueCallback
            #expect(watermark.revision == 4)
            #expect(before.map(\.uid) == ["q0", "q1", "q2"])
            #expect(mutation.next.map(\.uid) == ["q0", "q1", "q2", "", "a0"])
            #expect(mutation.prev.map(\.uid) == ["p0"])
            let ordering = runtime.queueInspectorOrderingVersion
            try #require(
                runtime.apply(
                    ProvenanceQueueSnapshot(
                        accountEpoch: runtime.accountEpoch, revision: 80, source: .webAPI, completeness: .complete,
                        receivedAt: HarnessDates.fixed, contextURI: "spotify:track:now",
                        entries: [
                            QueueEntry(uri: "spotify:track:reordered", provider: "web-api", occurrence: 0),
                            QueueEntry(uri: "spotify:track:dup", provider: "web-api", occurrence: 1),
                        ], tracks: [HarnessFixtures.track(uri: "spotify:track:dup", title: "Web Title")]),
                    engineEpoch: runtime.engineGeneration))
            #expect(runtime.queueNextEntries == before)
            #expect(runtime.queueMutation == mutation)
            #expect(runtime.connectQueueCallback == watermark)
            #expect(runtime.queueInspectorOrderingVersion == ordering)
            #expect(runtime.catalogMetadata.knownTrack(for: "spotify:track:dup")?.title == "Web Title")
            #expect(runtime.canRemoveUpcomingQueue(selectedIDs: [try #require(before.first).id]))
        }
    }

    @Test func newerGenerationAdoptsIdentityBeforeMetadataCompletes() async throws {
        let responses = HarnessResponseGate<SpotifyConnectTrackMetadata>()
        try await withQueueIntake(closing: { responses.close() }) { fixture in
            fixture.remote.onMetadata = { _ in try await responses.wait() }
            let runtime = fixture.runtime
            let oldGeneration = runtime.engineGeneration
            let generation = oldGeneration + 1
            let intake = try fixture.receive(intakeEnvelope(generation: generation))
            let metadata = try #require(intake.metadata)
            #expect(runtime.engineGeneration == generation)
            #expect(runtime.state.engineEpoch == generation)
            #expect(runtime.state.currentTrack?.uri == "spotify:track:now")
            #expect(!runtime.hasCurrentTrackMetadata)
            #expect(runtime.connectQueueCallback.generation == generation)
            #expect(runtime.connectQueueCallback.revision == 1)
            await intake.acceptance.wait()
            try await requireEventually { responses.waiterCount == 1 }
            #expect(runtime.queueMutation?.engineEpoch == generation)
            #expect(runtime.queueMutation?.engineEpoch != oldGeneration)
            responses.finish(HarnessFixtures.metadata(uri: "spotify:track:now"))
            await metadata.wait()
            #expect(runtime.state.currentTrack?.title == "Metadata")
            #expect(runtime.state.currentTrack?.uri == "spotify:track:now")
            #expect(runtime.engineGeneration == generation)
        }
    }

    @Test(arguments: [false, true])
    func rejectedCallbacksCannotRegisterWorkOrReplaceAcceptedState(staleGeneration: Bool) async throws {
        try await withQueueIntake { fixture in
            let runtime = fixture.runtime
            let generation = runtime.engineGeneration + 1
            let intake = try fixture.receive(intakeEnvelope(generation: generation))
            await intake.wait()
            let watermark = runtime.connectQueueCallback
            let mutation = runtime.queueMutation
            let track = runtime.state.currentTrack
            let metadataRequests = fixture.remote.requestedURIs
            runtime.receive(
                intakeEnvelope(
                    sequence: 2, revision: staleGeneration ? 2 : 1,
                    generation: staleGeneration ? generation - 1 : generation))
            // Admission rejects before scheduling: inspecting registrations in this actor turn is
            // stronger than giving an accidentally admitted worker a few chances to finish.
            #expect(runtime.effects.settlement(of: .connectQueueAccept) == nil)
            #expect(runtime.effects.settlement(of: .trackMetadata) == nil)
            #expect(runtime.connectQueueCallback == watermark)
            #expect(runtime.queueMutation == mutation)
            #expect(runtime.state.currentTrack == track)
            #expect(fixture.remote.requestedURIs == metadataRequests)
        }
    }

    @Test(arguments: [false, true])
    func terminationRejectsQueueIntakeWhileDrainingAndAfterCompletion(afterCompletion: Bool) async throws {
        let shutdownGate = HarnessEngineGate()
        try await withQueueIntake(closing: { shutdownGate.close() }) { fixture in
            let runtime = fixture.runtime
            fixture.engine.onShutdown = { shutdownGate.enter() }
            let shutdown = Task { await runtime.shutdownForTermination() }
            try await requireEventually { shutdownGate.enteredCount == 1 }
            if afterCompletion {
                shutdownGate.finish(with: .ok)
                await shutdown.value
            }
            let baseline = runtime.state
            let watermark = runtime.connectQueueCallback
            let mutation = runtime.queueMutation
            runtime.receive(intakeEnvelope(generation: runtime.engineGeneration + 1))
            #expect(runtime.effects.settlement(of: .connectQueueAccept) == nil)
            #expect(runtime.effects.settlement(of: .trackMetadata) == nil)
            #expect(runtime.state == baseline)
            #expect(runtime.connectQueueCallback == watermark)
            #expect(runtime.queueMutation == mutation)
            shutdownGate.close()
            await shutdown.value
        }
    }

    #if DEBUG
        @Test func admissionAndAcceptedOrderingHaveSeparateVersions() async throws {
            let suspension = HarnessSuspension()
            try await withQueueIntake(
                hook: QueueServiceSuspensionHook(accept: suspension), closing: { suspension.close() }
            ) { fixture in
                let runtime = fixture.runtime
                suspension.arm()
                let intake = try fixture.receive(intakeEnvelope(revision: 2, generation: runtime.engineGeneration))
                try await requireEventually { suspension.isWaiting }
                #expect(runtime.connectQueueCallback.revision == 2)
                #expect(runtime.queueInspectorOrderingVersion == 0)
                await intake.metadata?.wait()
                let stale = QueueEntry(uri: "spotify:track:stale", provider: "queue", occurrence: 0)
                let fallback = try #require(
                    await runtime.queueService.refresh(
                        fallbackEntries: [stale], cachedTracks: [HarnessFixtures.track(uri: stale.uri)],
                        currentTrackURI: runtime.trackURI, accountEpoch: runtime.accountEpoch))
                try #require(runtime.apply(fallback, engineEpoch: runtime.engineGeneration))
                #expect(runtime.queueNextEntries.map(\.uri) == [stale.uri])
                #expect(runtime.queueInspectorOrderingVersion == 0)
                suspension.resume()
                await intake.wait()
                #expect(runtime.queueNextEntries.map(\.uri) == ["spotify:track:dup", "spotify:track:other"])
                #expect(runtime.queueInspectorOrderingVersion == 1)
                let redelivery = try fixture.receive(
                    intakeEnvelope(sequence: 2, revision: 3, generation: runtime.engineGeneration))
                await redelivery.wait()
                #expect(runtime.queueMutation?.sourceRevision == 3)
                #expect(runtime.connectQueueCallback.revision == 3)
                #expect(runtime.queueInspectorOrderingVersion == 1)
            }
        }

        @Test(arguments: [false, true])
        func independentlyInvalidatedAcceptanceCannotInstallMutationOrOrdering(account: Bool) async throws {
            let suspension = HarnessSuspension()
            try await withQueueIntake(
                hook: QueueServiceSuspensionHook(accept: suspension), closing: { suspension.close() }
            ) { fixture in
                let runtime = fixture.runtime
                suspension.arm()
                let intake = try fixture.receive(intakeEnvelope(generation: runtime.engineGeneration))
                try await requireEventually { suspension.isWaiting }
                if account {
                    runtime.accountStore.advanceEpoch()
                } else {
                    try #require(
                        runtime.send(
                            .session(runtime.state.session), source: .account, engineEpoch: runtime.engineGeneration + 1
                        ))
                }
                suspension.resume()
                await intake.wait()
                #expect(runtime.queueMutation == nil)
                #expect(runtime.queueNextEntries.isEmpty)
                #expect(runtime.queueInspectorOrderingVersion == 0)
            }
        }

        @Test func terminationJoinsTheCancelledAcceptanceWithoutRestoringQueue() async throws {
            let suspension = HarnessSuspension()
            try await withQueueIntake(
                hook: QueueServiceSuspensionHook(accept: suspension), closing: { suspension.close() }
            ) { fixture in
                let runtime = fixture.runtime
                suspension.arm()
                let intake = try fixture.receive(intakeEnvelope(generation: runtime.engineGeneration))
                try await requireEventually { suspension.isWaiting }
                await runtime.shutdownForTermination()
                await intake.wait()
                #expect(runtime.queueMutation == nil)
                #expect(runtime.queueNextEntries.isEmpty)
                #expect(runtime.state.currentTrack == nil)
                #expect(runtime.queueInspectorOrderingVersion == 0)
                #expect(runtime.connectQueueCallback.revision == 0)
            }
        }
    #endif
}
