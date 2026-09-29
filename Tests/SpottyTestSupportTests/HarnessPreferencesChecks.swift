import SpottyTestSupport
import Testing

@MainActor
struct HarnessPreferencesChecks {
    @Test func optionalDeviceAndHistoryReadsKeepNilDistinctFromGateClosure() async throws {
        let devices = HarnessResponseGate<String?>()
        let history = HarnessResponseGate<[String: Double]>()
        defer { devices.close(); history.close() }
        let preferences = HarnessPreferences(
            lastRemoteDeviceID: "saved", shuffleHistory: ["saved": 1],
            remoteDeviceResponses: devices, historyResponses: history)
        devices.finish(nil)
        #expect(await preferences.lastRemoteDeviceID() == nil)
        history.finish([:])
        #expect(await preferences.shuffleHistory().isEmpty)
        #expect(preferences.storedRemoteDeviceID == "saved")
        #expect(preferences.storedHistory == ["saved": 1])
        devices.close()
        history.close()
        #expect(await preferences.lastRemoteDeviceID() == "saved")
        #expect(await preferences.shuffleHistory() == ["saved": 1])
    }

    @Test func scriptedReadsPreserveStorageAndClosingReleasesConcurrentReaders() async throws {
        let responses = HarnessResponseGate<Bool>(cancellation: .ignored)
        defer { responses.close() }
        let preferences = HarnessPreferences(shuffle: true, shuffleResponses: responses)
        responses.finish(false)
        #expect(await preferences.shuffleEnabled() == false)
        #expect(preferences.storedShuffle == true)
        #expect(preferences.shuffleWrites.isEmpty)

        let first = Task { await preferences.shuffleEnabled() }
        defer { first.cancel() }
        try await requireEventually { responses.waiterCount == 1 }
        let second = Task { await preferences.shuffleEnabled() }
        defer { second.cancel() }
        try await requireEventually { responses.waiterCount == 2 }
        first.cancel()
        responses.finish(false)
        #expect(await first.value == false, "ignored cancellation permits a deliberately late value")
        responses.close()
        #expect(await second.value == true, "cleanup falls back to stored state for a nonthrowing read")
        #expect(await preferences.shuffleEnabled() == true)
        #expect(preferences.storedShuffle == true)
    }

    @Test func historyIsCommittedOnlyAfterTheHookCompletes() async throws {
        let suspension = HarnessSuspension()
        defer { suspension.close() }
        suspension.arm()
        let preferences = HarnessPreferences(
            shuffleHistory: ["initial": 1],
            beforeHistoryWrite: { _ in
                await suspension.waitIfArmed()
            })
        let write = Task { await preferences.setShuffleHistory(["replacement": 2]) }
        defer { write.cancel() }
        try await requireEventually { suspension.isWaiting }
        #expect(preferences.storedHistory == ["initial": 1])
        #expect(preferences.historyWrites.isEmpty)
        suspension.resume()
        await write.value
        #expect(preferences.storedHistory == ["replacement": 2])
        #expect(preferences.historyWrites == [["replacement": 2]])
    }
}
