import Foundation
import SpottyRuntimeContracts
import Synchronization

/// In-memory preferences with synchronous snapshots. Tests own and close injected response gates.
package final class HarnessPreferences: PlaybackPreferences, Sendable {
    private struct State {
        var shuffle: Bool
        var remoteID: String?
        var history: [String: TimeInterval]
        var shuffleWrites: [Bool] = []
        var remoteDeviceWrites: [String?] = []
        var historyWrites: [[String: TimeInterval]] = []
    }

    private let state: Mutex<State>
    private let shuffleResponses: HarnessResponseGate<Bool>?
    private let remoteDeviceResponses: HarnessResponseGate<String?>?
    private let historyResponses: HarnessResponseGate<[String: TimeInterval]>?
    private let beforeShuffleWrite: @Sendable (Bool) async -> Void
    private let beforeHistoryWrite: @Sendable ([String: TimeInterval]) async -> Void

    package init(
        shuffle: Bool = false,
        lastRemoteDeviceID: String? = nil,
        shuffleHistory: [String: TimeInterval] = [:],
        shuffleResponses: HarnessResponseGate<Bool>? = nil,
        remoteDeviceResponses: HarnessResponseGate<String?>? = nil,
        historyResponses: HarnessResponseGate<[String: TimeInterval]>? = nil,
        beforeShuffleWrite: @escaping @Sendable (Bool) async -> Void = { _ in },
        beforeHistoryWrite: @escaping @Sendable ([String: TimeInterval]) async -> Void = { _ in }
    ) {
        state = Mutex(State(shuffle: shuffle, remoteID: lastRemoteDeviceID, history: shuffleHistory))
        self.shuffleResponses = shuffleResponses
        self.remoteDeviceResponses = remoteDeviceResponses
        self.historyResponses = historyResponses
        self.beforeShuffleWrite = beforeShuffleWrite
        self.beforeHistoryWrite = beforeHistoryWrite
    }

    package var shuffleWrites: [Bool] { state.withLock { $0.shuffleWrites } }
    package var remoteDeviceWrites: [String?] { state.withLock { $0.remoteDeviceWrites } }
    package var historyWrites: [[String: TimeInterval]] { state.withLock { $0.historyWrites } }
    package var storedRemoteDeviceID: String? { state.withLock { $0.remoteID } }
    package var storedShuffle: Bool { state.withLock { $0.shuffle } }
    package var storedHistory: [String: TimeInterval] { state.withLock { $0.history } }

    package func seed(lastRemoteDeviceID id: String?) { state.withLock { $0.remoteID = id } }

    package func shuffleEnabled() async -> Bool {
        if let shuffleResponses, let value = try? await shuffleResponses.wait() { return value }
        // The nonthrowing port uses stored state when a gate closes or cooperatively cancels.
        return storedShuffle
    }

    package func setShuffleEnabled(_ enabled: Bool) async {
        await beforeShuffleWrite(enabled)
        state.withLock {
            $0.shuffle = enabled
            $0.shuffleWrites.append(enabled)
        }
    }

    package func lastRemoteDeviceID() async -> String? {
        if let remoteDeviceResponses {
            do { return try await remoteDeviceResponses.wait() } catch { return storedRemoteDeviceID }
        }
        return storedRemoteDeviceID
    }

    package func setLastRemoteDeviceID(_ id: String?) async {
        state.withLock {
            $0.remoteID = id
            $0.remoteDeviceWrites.append(id)
        }
    }

    package func shuffleHistory() async -> [String: TimeInterval] {
        if let historyResponses, let value = try? await historyResponses.wait() { return value }
        return storedHistory
    }

    package func setShuffleHistory(_ history: [String: TimeInterval]) async {
        await beforeHistoryWrite(history)
        state.withLock {
            $0.history = history
            $0.historyWrites.append(history)
        }
    }
}
