import AppKit
import Foundation
import SpottyDomain
import Testing
@testable import SpottyCore
@testable import SpottyGateway
import SpottyRuntimeContracts

@Suite("Audit lifetime regressions")
@MainActor
struct AuditRegressionChecks {
    @Test func preferenceClearFollowsAnUncooperativeWriteAndFencesQueuedOldAccounts() async {
        let preferences = HarnessPreferences()
        let writer = PlaybackPreferenceWriter(preferences: preferences)
        let entered = KeymasterPersistenceReceipt<Void>()
        let release = KeymasterPersistenceReceipt<Void>()
        let old = ["spotify:track:old": 1.0]
        let writing = writer.submit(epoch: 1) {
            entered.resolve(())
            await release.value()
            await $0.setShuffleHistory(old)
            await $0.setLastRemoteDeviceID("old-device")
        }
        await entered.value()
        writer.submit(epoch: 1) { await $0.setShuffleHistory(["queued-old": 2]) }
        let clearing = writer.submit(epoch: 2) {
            await $0.setShuffleHistory([:])
            await $0.setLastRemoteDeviceID(nil)
        }
        let stale = writer.submit(epoch: 1) { await $0.setLastRemoteDeviceID("late-old") }
        writing.cancel()  // The already-entered write deliberately ignores cancellation.
        release.resolve(())
        await clearing.value
        await stale.value
        #expect(preferences.historyWrites == [old, [:]])
        #expect(preferences.storedHistory.isEmpty)
        #expect(preferences.remoteDeviceWrites == ["old-device", nil])
    }

    @Test func rejectedClientTokenFencesInflightFetchAndItsCleanup() async throws {
        let calls = HarnessCounters()
        let second = KeymasterPersistenceReceipt<Void>()
        let third = KeymasterPersistenceReceipt<Void>()
        let now = HarnessDates.fixed
        let provider = ClientTokenProvider(deviceIdStore: FixtureDeviceID()) { _ in
            calls.record("fetch")
            let index = calls.count("fetch")
            if index == 2 { await second.value() }
            if index == 3 { await third.value() }
            return GrantedClientToken(token: "token-\(index)", expiresAt: now.addingTimeInterval(index == 1 ? 10 : 100))
        }
        #expect(try await provider.token(now: now) == "token-1")
        let expired = now.addingTimeInterval(20)
        let superseded = Task { try await provider.token(now: expired) }
        await expectEventually { calls.count("fetch") == 2 }
        await provider.invalidate(rejected: "token-1")
        let replacement = Task { try await provider.token(now: expired) }
        await expectEventually { calls.count("fetch") == 3 }
        second.resolve(())
        await #expect(throws: CancellationError.self) { try await superseded.value }
        let joiner = Task { try await provider.token(now: expired) }
        third.resolve(())
        #expect(try await replacement.value == "token-3")
        #expect(try await joiner.value == "token-3")
        await provider.invalidate(rejected: "token-1")
        #expect(try await provider.token(now: expired) == "token-3")
        #expect(calls.count("fetch") == 3)
    }

    @Test func mediaAdmissionDoesNotWaitForTheMainActor() {
        let admission = SystemMediaAdmission()
        #expect(admission.admit(.toggle) == nil)
        admission.update(
            SystemMediaSnapshot(
                title: "Fixture", artist: "Fixture", duration: 60,
                position: 0, playing: false, canToggle: true, canSkip: false))
        let finished = DispatchSemaphore(value: 0)
        let calls = HarnessCounters()
        DispatchQueue.global().async {
            if admission.admit(.toggle) != nil && admission.admit(.next) == nil { calls.record("accepted") }
            finished.signal()
        }
        // Deliberately occupy main: the media callback must still return independently.
        #expect(finished.wait(timeout: .now() + 5) == .success)
        #expect(calls.count("accepted") == 1)
        let admitted = admission.admit(.play)
        admission.update(nil)
        #expect(admission.admit(.play) == nil)
        #expect(admitted.map { admission.isCurrent($0) } == false)
    }

    @Test func catalogErrorCopyDoesNotExposeTransportDetails() {
        #expect(
            CatalogErrorPresentation.message(for: CatalogReadFailure.compatibility)
                == "Spotify changed how this content loads. Update Spotty to try again.")
        #expect(
            CatalogErrorPresentation.message(for: CatalogReadFailure.offline).contains("Check your connection"))
        #expect(CatalogErrorPresentation.message(for: CatalogReadFailure.sessionExpired).contains("Sign in again"))
        #expect(
            CatalogErrorPresentation.message(for: CatalogReadFailure.unavailable)
                == "Couldn't load this content from Spotify. Try again.")
    }
}

// DeviceIdStoring is a separate engine-adapter boundary, not part of the playback harness.
private struct FixtureDeviceID: DeviceIdStoring {
    func deviceId() -> String { "synthetic-device" }
}
