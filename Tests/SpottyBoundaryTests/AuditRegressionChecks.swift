import SpottyTestSupport
import AppKit
import Foundation
import SpottyDomain
import Testing
@testable import SpottyCore

@Suite("Audit lifetime regressions")
@MainActor
struct AuditRegressionChecks {
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
