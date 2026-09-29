import Foundation
import SpottyDomain
import SpottyEngineAdapter
import SpottyTestSupport
import Testing
@testable import SpottyRuntimeTestSupport
@testable import SpottySessionRuntime

@Suite("Preference restoration")
@SessionRuntimeActor
struct PreferenceRestorationTests {
    enum ShuffleActivity: CaseIterable { case preferenceOnly, acceptedCommand, engineObservation }
    enum ShuffleObservation: CaseIterable { case equalDefault, missing, stale }
    enum CancelledRead: CaseIterable { case shuffle, remote, history }

    @Test func playbackAfterCancelledHistoryRestorationStillMergesTheSavedBaseline() async throws {
        let responses = HarnessResponseGate<[String: TimeInterval]>(cancellation: .ignored)
        let now = HarnessDates.fixed.timeIntervalSince1970
        let saved = ["saved": now - 100]
        let preferences = HarnessPreferences(shuffleHistory: saved, historyResponses: responses)
        try await withRestoration(preferences, close: { responses.close() }) { runtime, restoring in
            try await requireEventually { responses.waiterCount == 1 }
            let cancelled = runtime.effects.cancel(.preferencesRestore)
            try #require(cancelled != nil)
            responses.finish(saved)
            await restoring.wait()
            try #require(runtime.shuffleHistoryCache.isEmpty)
            runtime.recordPlayed("new")
            try await requireEventually {
                responses.requestCount == 2 || !preferences.historyWrites.isEmpty
            }
            #expect(preferences.historyWrites.isEmpty, "Cancelling a seed cannot authorize a partial history write")
            responses.finish(saved)
            await runtime.preferenceState.flush()
            #expect(runtime.shuffleHistoryCache == ["saved": now - 100, "new": now])
            #expect(preferences.storedHistory == ["saved": now - 100, "new": now])
        }
    }

    @Test(arguments: CancelledRead.allCases)
    func cancellingRestorationRejectsLateSeedsEvenWhenTheAccountRemainsCurrent(_ stage: CancelledRead) async throws {
        let shuffle = HarnessResponseGate<Bool>(cancellation: .ignored)
        let devices = HarnessResponseGate<String?>(cancellation: .ignored)
        let history = HarnessResponseGate<[String: TimeInterval]>(cancellation: .ignored)
        let preferences = HarnessPreferences(
            shuffle: true, lastRemoteDeviceID: "saved", shuffleHistory: ["saved": 1],
            shuffleResponses: shuffle, remoteDeviceResponses: devices, historyResponses: history)
        try await withRestoration(
            preferences,
            close: {
                shuffle.close(); devices.close(); history.close()
            }
        ) { runtime, restoring in
            try await requireEventually { shuffle.waiterCount == 1 }
            if stage != .shuffle {
                shuffle.finish(true)
                try await requireEventually { devices.waiterCount == 1 }
            }
            if stage == .history {
                devices.finish("saved")
                try await requireEventually { history.waiterCount == 1 }
            }
            let options = runtime.state.options
            let remoteID = runtime.lastRemoteDeviceID
            let savedHistory = runtime.shuffleHistoryCache
            let cancellation = runtime.effects.cancel(.preferencesRestore)
            try #require(cancellation != nil)
            shuffle.close()
            devices.close()
            history.close()
            await restoring.wait()
            #expect(runtime.state.options == options)
            #expect(runtime.lastRemoteDeviceID == remoteID)
            #expect(runtime.shuffleHistoryCache == savedHistory)
            #expect(preferences.historyWrites.isEmpty)
        }
    }

    @Test func anUncontestedStartupRestoresAllSeedsWithoutRewritingStorage() async throws {
        let saved = ["saved": 1.0]
        let preferences = HarnessPreferences(shuffle: true, lastRemoteDeviceID: "phone", shuffleHistory: saved)
        try await withRestoration(preferences, close: {}) { runtime, restoring in
            await restoring.wait()
            #expect(runtime.state.options.shuffle)
            #expect(runtime.lastRemoteDeviceID == "phone")
            #expect(runtime.shuffleHistoryCache == saved, "Restoration alone does not prune history")
            #expect(preferences.shuffleWrites.isEmpty)
            #expect(preferences.remoteDeviceWrites.isEmpty)
            #expect(preferences.historyWrites.isEmpty)
        }
    }

    @Test func aSuspendedPreferenceSeedDoesNotKeepTheRuntimeAlive() async throws {
        let responses = HarnessResponseGate<Bool>(cancellation: .ignored)
        defer { responses.close() }
        let preferences = HarnessPreferences(shuffleResponses: responses)
        var runtime: PlaybackSessionRuntime? = PlaybackSessionRuntime(
            environment: HarnessEnvironment.make(preferences: preferences))
        weak let owner = runtime
        runtime?.startLifetimeEffectsIfNeeded()
        let restoring = try #require(runtime?.effects.settlement(of: .preferencesRestore))
        do {
            try await requireEventually { responses.waiterCount == 1 }
            runtime = nil
            await Task { @SessionRuntimeActor in }.value
            #expect(owner == nil)
        } catch {
            responses.close()
            await restoring.wait()
            await runtime?.shutdownForTermination()
            throw error
        }
        responses.close()
        await restoring.wait()
        // Also retire a retained owner when deliberately testing broken ownership.
        await owner?.shutdownForTermination()
    }

    @Test func playbackBeforeRestorationPreservesPreviouslySavedHistory() async throws {
        let responses = HarnessResponseGate<Bool>(cancellation: .ignored)
        let saved = ["spotify:track:old": HarnessDates.fixed.timeIntervalSince1970 - 100]
        let preferences = HarnessPreferences(shuffleHistory: saved, shuffleResponses: responses)
        try await withRestoration(preferences, close: { responses.close() }) { runtime, restoring in
            try await requireEventually { responses.waiterCount == 1 }
            runtime.recordPlayed("spotify:track:new")
            let newPlay = try #require(runtime.shuffleHistoryCache["spotify:track:new"])
            await runtime.preferenceState.flush()
            responses.finish(false)
            await restoring.wait()
            #expect(runtime.shuffleHistoryCache["spotify:track:old"] == saved["spotify:track:old"])
            #expect(runtime.shuffleHistoryCache["spotify:track:new"] == newPlay)
            #expect(preferences.storedHistory["spotify:track:old"] == saved["spotify:track:old"])
            #expect(preferences.storedHistory["spotify:track:new"] == newPlay)
        }
    }

    @Test(arguments: ShuffleActivity.allCases)
    func aLateStoredShuffleCannotOverwriteNewerSameAccountActivity(_ activity: ShuffleActivity) async throws {
        let responses = HarnessResponseGate<Bool>(cancellation: .ignored)
        let preferences = HarnessPreferences(shuffleResponses: responses)
        try await withRestoration(preferences, close: { responses.close() }) { runtime, restoring in
            try await requireEventually { responses.waiterCount == 1 }
            if activity != .preferenceOnly { try prepareLocalPlayback(runtime) }
            switch activity {
            case .preferenceOnly:
                runtime.toggleShuffle()
            case .acceptedCommand:
                runtime.toggleShuffle()
                let command = try #require(runtime.state.pendingCommands[.options])
                let settled = try #require(runtime.effects.settlement(of: .command(command.id)))
                await settled.wait()
            case .engineObservation:
                try #require(
                    runtime.send(.enginePlayback(playback(shuffle: true)), source: .enginePlayback, revision: 1))
            }
            try #require(runtime.state.options.shuffle)
            await runtime.preferenceState.flush()
            responses.finish(false)
            await restoring.wait()
            #expect(runtime.state.options.shuffle)
        }
    }

    @Test func changingShuffleAwayAndBackStillSupersedesTheSeed() async throws {
        let responses = HarnessResponseGate<Bool>(cancellation: .ignored)
        let preferences = HarnessPreferences(shuffle: true, shuffleResponses: responses)
        try await withRestoration(preferences, close: { responses.close() }) { runtime, restoring in
            try await requireEventually { responses.waiterCount == 1 }
            runtime.toggleShuffle()
            runtime.toggleShuffle()
            try #require(!runtime.state.options.shuffle)
            responses.finish(true)
            await restoring.wait()
            await runtime.preferenceState.flush()
            #expect(!runtime.state.options.shuffle)
            #expect(!preferences.storedShuffle)
        }
    }

    @Test(arguments: ShuffleObservation.allCases, [false, true])
    func onlyAcceptedShuffleObservationsSupersedeTheSeed(_ observation: ShuffleObservation, aggregated: Bool)
        async throws
    {
        let responses = HarnessResponseGate<Bool>(cancellation: .ignored)
        let preferences = HarnessPreferences(shuffle: true, shuffleResponses: responses)
        try await withRestoration(preferences, close: { responses.close() }) { runtime, restoring in
            try await requireEventually { responses.waiterCount == 1 }
            try #require(runtime.send(.session(.ready), source: .account))
            if observation == .stale {
                try #require(
                    runtime.send(.enginePlayback(playback(shuffle: nil)), source: .enginePlayback, revision: 2))
            }
            let snapshot = playback(shuffle: observation == .missing ? nil : false)
            if aggregated {
                try #require(
                    runtime.send(
                        .engineCluster(
                            EngineConnectSnapshot(
                                devices: PlaybackDeviceSnapshot(devices: [], localDeviceID: "mac", revision: 3),
                                connection: nil, connectionRevision: nil, playback: snapshot, playbackRevision: 1)),
                        source: .engineCluster, revision: 3))
            } else {
                let accepted = runtime.send(.enginePlayback(snapshot), source: .enginePlayback, revision: 1)
                #expect(accepted == (observation != .stale))
            }
            responses.finish(true)
            await restoring.wait()
            #expect(runtime.state.options.shuffle == (observation != .equalDefault))
            #expect(preferences.shuffleWrites.isEmpty, "Engine truth does not persist a user choice")
        }
    }

    @Test func anAdmittedShuffleSupersedesRestorationBeforeItsReplyAndKeepsRollback() async throws {
        let responses = HarnessResponseGate<Bool>(cancellation: .ignored)
        let commands = HarnessEngineGate()
        let engine = HarnessEngine()
        engine.onExecute = { _ in commands.enter() }
        let preferences = HarnessPreferences(shuffleResponses: responses)
        try await withRestoration(
            preferences, engine: engine,
            close: {
                responses.close(); commands.close()
            }
        ) { runtime, restoring in
            try await requireEventually { responses.waiterCount == 1 }
            try prepareLocalPlayback(runtime)
            runtime.toggleShuffle()
            let command = try #require(runtime.state.pendingCommands[.options])
            let settled = try #require(runtime.effects.settlement(of: .command(command.id)))
            try await requireEventually { commands.enteredCount == 1 }
            responses.finish(false)
            await restoring.wait()
            #expect(runtime.state.options.shuffle, "Startup cannot roll back an admitted choice")
            commands.finish(with: .error)
            await settled.wait()
            #expect(!runtime.state.options.shuffle, "The command still owns its failure rollback")
            #expect(preferences.shuffleWrites.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func rememberedRemoteObservationWinsWhetherItPrecedesOrOverlapsItsRead(beforeRead: Bool) async throws {
        let shuffle = HarnessResponseGate<Bool>(cancellation: .ignored)
        let devices = HarnessResponseGate<String?>(cancellation: .ignored)
        let preferences = HarnessPreferences(
            lastRemoteDeviceID: "old", shuffleResponses: shuffle, remoteDeviceResponses: devices)
        try await withRestoration(
            preferences,
            close: {
                shuffle.close(); devices.close()
            }
        ) { runtime, restoring in
            try await requireEventually { shuffle.waiterCount == 1 }
            try prepareLocalPlayback(runtime)
            if !beforeRead {
                shuffle.finish(false)
                try await requireEventually { devices.waiterCount == 1 }
            }
            runtime.receive(
                [ConnectDevice(id: "phone", name: "Phone", type: "smartphone", isActive: true)],
                revision: 2, engineEpoch: runtime.engineGeneration)
            try #require(runtime.lastRemoteDeviceID == "phone")
            if beforeRead {
                shuffle.finish(false)
                try await requireEventually { devices.waiterCount == 1 }
            }
            devices.finish("old")
            await restoring.wait()
            await runtime.preferenceState.flush()
            #expect(runtime.lastRemoteDeviceID == "phone")
            #expect(preferences.storedRemoteDeviceID == "phone")
        }
    }

    @Test func historyMergesOnlyAfterTheBaselineArrivesAndNewOccurrencesWinAcrossClockRollback() async throws {
        let responses = HarnessResponseGate<[String: TimeInterval]>(cancellation: .ignored)
        let clock = HarnessClock.sticky()
        let now = clock.now().timeIntervalSince1970
        let saved = ["old": now - 100, "overlap": now + 100, "expired": now - ShufflePolicy.retention - 100]
        let preferences = HarnessPreferences(shuffleHistory: saved, historyResponses: responses)
        try await withRestoration(preferences, clock: clock, close: { responses.close() }) { runtime, restoring in
            try await requireEventually { responses.waiterCount == 1 }
            runtime.recordPlayed("new")
            runtime.recordPlayed("overlap")
            clock.set(now: HarnessDates.fixed.addingTimeInterval(-10))
            runtime.recordPlayed("overlap")
            #expect(runtime.shuffleHistoryCache == ["new": now, "overlap": now - 10])
            #expect(preferences.storedHistory == saved)
            #expect(preferences.historyWrites.isEmpty, "A partial cache cannot replace saved history")
            responses.finish(saved)
            await restoring.wait()
            await runtime.preferenceState.flush()
            let expected = ["old": now - 100, "new": now, "overlap": now - 10]
            #expect(runtime.shuffleHistoryCache == expected)
            #expect(preferences.historyWrites == [expected])
            clock.advance(seconds: 1)
            runtime.recordPlayed("after")
            await runtime.preferenceState.flush()
            #expect(preferences.storedHistory["after"] == now - 9)
            #expect(preferences.storedHistory["old"] == now - 100)
        }
    }

    @Test func accountRetirementDoesNotWaitForAnIgnoredHistoryReadAndItsLateResultIsInert() async throws {
        let responses = HarnessResponseGate<[String: TimeInterval]>(cancellation: .ignored)
        let saved = ["old-account": HarnessDates.fixed.timeIntervalSince1970]
        let preferences = HarnessPreferences(
            lastRemoteDeviceID: "old-device", shuffleHistory: saved, historyResponses: responses)
        try await withRestoration(preferences, close: { responses.close() }) { runtime, restoring in
            try await requireEventually { responses.waiterCount == 1 }
            runtime.recordPlayed("pending-old-play")
            await runtime.logout()
            #expect(responses.waiterCount == 1, "Account clearing must not depend on this read")
            #expect(runtime.shuffleHistoryCache.isEmpty)
            #expect(preferences.storedHistory.isEmpty)
            #expect(preferences.storedRemoteDeviceID == nil)
            responses.finish(saved)
            await restoring.wait()
            await runtime.preferenceState.flush()
            #expect(runtime.shuffleHistoryCache.isEmpty)
            #expect(preferences.historyWrites == [[:]])
            #expect(runtime.lastRemoteDeviceID == nil)
        }
    }

    @Test func quitWaitsForAcceptedHistoryToMergeAndPersistWithoutPublishingLateSeeds() async throws {
        let responses = HarnessResponseGate<[String: TimeInterval]>(cancellation: .ignored)
        let now = HarnessDates.fixed.timeIntervalSince1970
        let saved = ["saved": now - 100]
        let preferences = HarnessPreferences(shuffleHistory: saved, historyResponses: responses)
        let engine = HarnessEngine()
        try await withRestoration(preferences, engine: engine, close: { responses.close() }) { runtime, restoring in
            try await requireEventually { responses.waiterCount == 1 }
            runtime.recordPlayed("new")
            var finished = false
            let shutdown = Task {
                await runtime.shutdownForTermination(); finished = true
            }
            defer { shutdown.cancel() }
            do {
                try await requireEventually { engine.shutdownCount == 1 }
                #expect(!finished)
                #expect(preferences.historyWrites.isEmpty)
                responses.finish(saved)
                await shutdown.value
                await restoring.wait()
                #expect(preferences.storedHistory == ["saved": now - 100, "new": now])
                #expect(runtime.shuffleHistoryCache == ["new": now], "The retired runtime does not restore late values")
            } catch {
                responses.close()
                await shutdown.value
                throw error
            }
        }
    }

    @Test func quitWithoutNewPlaysDoesNotWaitForAnIgnoredHistorySeed() async throws {
        let responses = HarnessResponseGate<[String: TimeInterval]>(cancellation: .ignored)
        let saved = ["saved": HarnessDates.fixed.timeIntervalSince1970]
        let preferences = HarnessPreferences(shuffleHistory: saved, historyResponses: responses)
        try await withRestoration(preferences, close: { responses.close() }) { runtime, restoring in
            try await requireEventually { responses.waiterCount == 1 }
            await runtime.shutdownForTermination()
            #expect(responses.waiterCount == 1)
            responses.finish(saved)
            await restoring.wait()
            #expect(runtime.shuffleHistoryCache.isEmpty)
            #expect(preferences.storedHistory == saved)
            #expect(preferences.historyWrites.isEmpty)
        }
    }

    private func playback(shuffle: Bool?) -> EnginePlaybackSnapshot {
        EnginePlaybackSnapshot(
            transport: .paused, trackURI: nil, timing: PlaybackTiming(anchoredAt: HarnessDates.fixed), shuffle: shuffle)
    }

    private func prepareLocalPlayback(_ runtime: PlaybackSessionRuntime) throws {
        try #require(runtime.send(.session(.ready), source: .account))
        try #require(
            runtime.send(
                .devices(
                    PlaybackDeviceSnapshot(
                        devices: [PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: true)],
                        localDeviceID: "mac", revision: 1)), source: .engineDevices, revision: 1))
    }

    private func withRestoration(
        _ preferences: HarnessPreferences,
        engine: HarnessEngine = HarnessEngine(),
        clock: HarnessClock = .sticky(),
        close: () -> Void,
        body: (PlaybackSessionRuntime, PlaybackEffectSettlement) async throws -> Void
    ) async throws {
        defer { close() }
        let runtime = PlaybackSessionRuntime(
            environment: HarnessEnvironment.make(engine: engine, preferences: preferences, clock: clock))
        runtime.startLifetimeEffectsIfNeeded()
        let restoring = try #require(runtime.effects.settlement(of: .preferencesRestore))
        do {
            try await body(runtime, restoring)
        } catch {
            close()
            await restoring.wait()
            await runtime.shutdownForTermination()
            throw error
        }
        close()
        await restoring.wait()
        await runtime.shutdownForTermination()
    }
}
