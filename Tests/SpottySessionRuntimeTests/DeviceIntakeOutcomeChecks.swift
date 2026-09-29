@testable import SpottyRuntimeTestSupport
import SpottyTestSupport
import Testing
import SpottyDomain
import SpottyRuntimeContracts
import SpottyEngineAdapter
@testable import SpottySessionRuntime

private let intakeMac = ConnectDevice(id: "mac", name: "Mac", type: "computer", isActive: false)
private let intakePhone = ConnectDevice(id: "phone", name: "Phone", type: "smartphone", isActive: false)
private let intakeActivePhone = ConnectDevice(id: "phone", name: "Phone", type: "smartphone", isActive: true)

@SessionRuntimeActor
private func withDeviceIntake(
    preferences: HarnessPreferences,
    engine: HarnessEngine = HarnessEngine(),
    _ body: @SessionRuntimeActor (PlaybackSessionRuntime) async throws -> Void
) async throws {
    let runtime = PlaybackSessionRuntime(environment: HarnessEnvironment.make(engine: engine, preferences: preferences))
    _ = runtime.send(.session(.ready), source: .account)
    _ = runtime.send(
        .engineConnection(EngineConnectionSnapshot(session: .ready, owner: .none, localDeviceID: "mac")),
        source: .engineConnection, revision: 1, engineEpoch: 1)
    do {
        try await body(runtime)
    } catch {
        await runtime.shutdownForTermination()
        throw error
    }
    await runtime.shutdownForTermination()
}

@Suite("Device intake outcomes")
@SessionRuntimeActor
struct DeviceIntakeOutcomeTests {
    @Test func acceptedRemoteOwnerPersistsItsIdentity() async throws {
        let preferences = HarnessPreferences()
        try await withDeviceIntake(preferences: preferences) { runtime in
            runtime.receive([intakeMac, intakeActivePhone], revision: 1, engineEpoch: runtime.engineGeneration)
            #expect(
                runtime.state.owner
                    == .remote(PlaybackDevice(id: "phone", name: "Phone", type: "smartphone", isActive: true)))
            #expect(runtime.lastRemoteDeviceID == "phone")
            await runtime.preferenceState.flush()
            #expect(preferences.storedRemoteDeviceID == "phone")
        }
    }

    @Test(arguments: [false, true])
    func repeatedDeviceObservationsDoNotRewriteAnUnchangedSavedIdentity(restored: Bool) async throws {
        let preferences = HarnessPreferences(lastRemoteDeviceID: restored ? "phone" : nil)
        try await withDeviceIntake(preferences: preferences) { runtime in
            if restored { await runtime.preferenceState.restore(applyShuffle: { _ in }) }
            for revision in UInt64(1)...20 {
                let renamed = ConnectDevice(id: "phone", name: "Phone \(revision)", type: "smartphone", isActive: true)
                runtime.receive([intakeMac, renamed], revision: revision, engineEpoch: runtime.engineGeneration)
                #expect(runtime.state.devices.revision == revision, "Every new observation is still accepted")
                #expect(
                    runtime.state.owner
                        == .remote(PlaybackDevice(id: "phone", name: renamed.name, type: "smartphone", isActive: true)))
                // Join each write so queue coalescing cannot conceal redundant storage calls.
                await runtime.preferenceState.flush()
            }
            let initialWrites: [String?] = restored ? [] : ["phone"]
            #expect(preferences.remoteDeviceWrites == initialWrites)
            #expect(runtime.lastRemoteDeviceID == "phone")
            let speaker = ConnectDevice(id: "speaker", name: "Speaker", type: "speaker", isActive: true)
            runtime.receive([intakeMac, speaker], revision: 21, engineEpoch: runtime.engineGeneration)
            await runtime.preferenceState.flush()
            runtime.receive([intakeMac, intakeActivePhone], revision: 22, engineEpoch: runtime.engineGeneration)
            await runtime.preferenceState.flush()
            #expect(preferences.remoteDeviceWrites == initialWrites + ["speaker", "phone"])
            runtime.preferenceState.forgetRemoteDevice()
            await runtime.preferenceState.flush()
            runtime.receive([intakeMac, intakeActivePhone], revision: 23, engineEpoch: runtime.engineGeneration)
            await runtime.preferenceState.flush()
            #expect(preferences.remoteDeviceWrites == initialWrites + ["speaker", "phone", nil, "phone"])
            #expect(preferences.storedRemoteDeviceID == "phone")
        }
    }

    @Test func staleDeviceIntakeCannotReplaceOrPersistRemoteIdentity() async throws {
        let preferences = HarnessPreferences()
        preferences.seed(lastRemoteDeviceID: "phone")
        try await withDeviceIntake(preferences: preferences) { runtime in
            runtime.preferenceState.rememberRemoteDevice("phone", accountEpoch: runtime.accountEpoch)
            runtime.receive([intakeMac, intakePhone], revision: 4, engineEpoch: runtime.engineGeneration)
            let accepted = runtime.state
            let staleActive = ConnectDevice(id: "tablet", name: "Tablet", type: "tablet", isActive: true)
            runtime.receive([intakeMac, staleActive], revision: 3, engineEpoch: runtime.engineGeneration)
            #expect(runtime.state == accepted, "an older device revision is inert")
            runtime.receive([intakeMac, staleActive], revision: 5, engineEpoch: 0)
            #expect(runtime.state == accepted, "an older engine generation is inert")
            #expect(
                !runtime.send(
                    .devices(
                        PlaybackDeviceSnapshot(
                            devices: [
                                PlaybackDevice(id: "mac", name: "Mac", type: "computer"),
                                PlaybackDevice(id: "tablet", name: "Tablet", type: "tablet", isActive: true),
                            ],
                            localDeviceID: "mac", revision: 5, lastRemoteDeviceID: "phone")),
                    source: .engineDevices, revision: 5, engineEpoch: runtime.engineGeneration, accountEpoch: 0))
            #expect(runtime.state == accepted, "an older account generation is inert")
            await runtime.preferenceState.flush()
            #expect(runtime.lastRemoteDeviceID == "phone")
            #expect(preferences.storedRemoteDeviceID == "phone", "rejected intake cannot persist a different device")
        }
    }

    @Test func terminatingRuntimeRejectsDeviceCallbacksAndPreferenceWrites() async throws {
        let preferences = HarnessPreferences()
        let engine = HarnessEngine()
        try await withDeviceIntake(preferences: preferences, engine: engine) { runtime in
            let shutdown = Task { await runtime.shutdownForTermination() }
            try await requireEventually { runtime.isTearingDown }
            let retired = runtime.state
            let retainedRemote = runtime.lastRemoteDeviceID
            let persistedRemote = preferences.storedRemoteDeviceID
            runtime.receive([intakeMac, intakeActivePhone], revision: 1, engineEpoch: runtime.engineGeneration)
            await shutdown.value
            await runtime.preferenceState.flush()
            #expect(runtime.state == retired)
            #expect(runtime.lastRemoteDeviceID == retainedRemote)
            #expect(preferences.storedRemoteDeviceID == persistedRemote)
            #expect(engine.shutdownCount == 1)
            #expect(runtime.effects.settlements().isEmpty)
        }
    }
}
