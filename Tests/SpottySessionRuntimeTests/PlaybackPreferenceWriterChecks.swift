import SpottyTestSupport
import Testing
@testable import SpottySessionRuntime

@SessionRuntimeActor
struct PlaybackPreferenceWriterChecks {
    @Test func pendingPreferencesKeepOnlyTheLatestValueForEachKey() async throws {
        let release = HarnessResponseGate<Void>(cancellation: .ignored)
        defer { release.close() }
        let initial = ["initial": 1.0]
        let preferences = HarnessPreferences(beforeHistoryWrite: { history in
            if history == initial { try? await release.wait() }
        })
        let writer = PlaybackPreferenceWriter(preferences: preferences)
        writer.submit(epoch: 1, .history(initial))
        try await requireEventually { release.waiterCount == 1 }
        for index in 0..<100 {
            writer.submit(epoch: 1, .history(["latest": Double(index)]))
            writer.submit(epoch: 1, .shuffle(index.isMultiple(of: 2)))
            writer.submit(epoch: 1, .remoteDevice("device-\(index)"))
        }
        writer.submit(epoch: 1, .remoteDevice("final-device"))
        release.finish(())
        await writer.flush()
        #expect(preferences.historyWrites.count == 2)
        #expect(preferences.storedHistory == ["latest": 99])
        #expect(preferences.shuffleWrites.count == 1)
        #expect(preferences.storedShuffle == false)
        #expect(preferences.remoteDeviceWrites.count == 1)
        #expect(preferences.storedRemoteDeviceID == "final-device")
    }

    @Test func preferenceClearFollowsAnUncooperativeWriteAndFencesQueuedOldAccounts() async throws {
        let release = HarnessResponseGate<Void>(cancellation: .ignored)
        defer { release.close() }
        let old = ["spotify:track:old": 1.0]
        let preferences = HarnessPreferences(beforeHistoryWrite: { history in
            if history == old { try? await release.wait() }
        })
        let writer = PlaybackPreferenceWriter(preferences: preferences)
        writer.submit(epoch: 1, .history(old))
        try await requireEventually { release.waiterCount == 1 }
        writer.submit(epoch: 1, .history(["queued-old": 2]))
        writer.submit(epoch: 1, .remoteDevice("queued-old-device"))
        writer.submit(epoch: 2, .history([:]))
        writer.submit(epoch: 2, .remoteDevice(nil))
        writer.submit(epoch: 1, .history(["late-old": 2]))
        let clearing = Task { await writer.flush() }
        defer { clearing.cancel() }
        clearing.cancel()  // Caller cancellation cannot discard accepted persistence or account clears.
        release.finish(())
        await clearing.value
        #expect(preferences.historyWrites == [old, [:]])
        #expect(preferences.storedHistory.isEmpty)
        #expect(preferences.remoteDeviceWrites == [nil])
    }
}
