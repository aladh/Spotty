import Foundation
import SpottyDomain
import SpottyRuntimeContracts
import Testing
@testable import SpottySessionRuntime

struct SessionServiceContractTests {
    @Test func queueBatchCannotConfirmFromOneOccurrenceOrTransportAcceptance() {
        #expect(serviceAggregateDisposition([.observedConfirmed], expectedCount: 2) == .dispatched)
        #expect(serviceAggregateDisposition([.sent, .observedConfirmed], expectedCount: 2) == .sent)
        #expect(
            serviceAggregateDisposition([.observedConfirmed, .observedConfirmed], expectedCount: 2)
                == .observedConfirmed)
        #expect(serviceAggregateDisposition([.sent, .rejected], expectedCount: 2) == .unknown)
        #expect(serviceAggregateDisposition([.rejected], expectedCount: 2) == .rejected)
        #expect(serviceAggregateDisposition([.expired], expectedCount: 1) == .expired)
        #expect(serviceAggregateDisposition([.unknown], expectedCount: 1) == .unknown)
    }

    @Test func snapshotsStayBoundedAndNeverAuthorizePartialQueueReplacement() throws {
        var snapshot = SessionSnapshot(sessionID: UUID(), revision: 12)
        snapshot.capabilities = [.queueRemove, .transport]
        snapshot.queue = PlaybackQueueSnapshot(
            entries: (0..<5_000).map {
                PlaybackQueueItem(uri: "spotify:track:\($0)", provider: "context", occurrence: $0, uid: "uid-\($0)")
            }, source: .connect, completeness: .complete)
        snapshot.devices.devices = (0..<300).map {
            PlaybackDevice(id: "device-\($0)", name: "Speaker", type: "computer")
        }
        let bounded = boundedServiceSnapshot(snapshot)
        #expect(bounded.queue.entries.count == 4_096)
        #expect(bounded.queue.completeness == .partial)
        #expect(!bounded.capabilities.contains(.queueRemove))
        #expect(bounded.capabilities.contains(.transport))
        #expect(bounded.devices.devices.count == 256)
        #expect(try JSONEncoder().encode(bounded).count < 2 * 1_024 * 1_024)
        #expect(bounded.queue.entries.first == snapshot.queue.entries.first)
    }

    @Test func snapshotsBoundEscapedPayloadBytesAndPreserveIdentifiers() throws {
        let uri = "spotify:track:" + String(repeating: "\\", count: 2_000)
        var snapshot = SessionSnapshot(sessionID: UUID(), revision: 13)
        snapshot.capabilities = [.queueRemove]
        snapshot.queue = PlaybackQueueSnapshot(
            entries: (0..<4_096).map {
                PlaybackQueueItem(uri: uri, provider: "context", occurrence: $0, uid: "uid-\($0)")
            }, source: .connect, completeness: .complete)
        snapshot.presentation.timing.position = .infinity
        snapshot.presentation.timing.duration = .nan
        let bounded = boundedServiceSnapshot(snapshot)
        #expect(try JSONEncoder().encode(bounded).count <= 1_900_000)
        #expect(bounded.queue.entries.count < snapshot.queue.entries.count)
        #expect(bounded.queue.entries.first?.uri == uri)
        #expect(bounded.queue.completeness == .partial)
        #expect(bounded.presentation.timing.position.isFinite)
        #expect(bounded.presentation.timing.duration.isFinite)
    }
}
