import Foundation
import SpottyRuntimeContracts

/// One worker persists the latest pending value of each preference. An account boundary drops
/// queued old values but still waits for an entered write before applying the new account's clears.
@SessionRuntimeActor
final class PlaybackPreferenceWriter {
    enum Change: Sendable {
        case shuffle(Bool)
        case history([String: TimeInterval])
        case remoteDevice(String?)

        func hasSameKey(as other: Self) -> Bool {
            switch (self, other) {
            case (.shuffle, .shuffle), (.history, .history), (.remoteDevice, .remoteDevice): true
            default: false
            }
        }

        func write(to preferences: any PlaybackPreferences) async {
            switch self {
            case let .shuffle(enabled): await preferences.setShuffleEnabled(enabled)
            case let .history(history): await preferences.setShuffleHistory(history)
            case let .remoteDevice(id): await preferences.setLastRemoteDeviceID(id)
            }
        }
    }

    private let preferences: any PlaybackPreferences
    private var epoch: UInt64 = 0
    private var pending: [Change] = []
    private var worker: Task<Void, Never>?

    init(preferences: any PlaybackPreferences) { self.preferences = preferences }

    func submit(epoch: UInt64, _ change: Change) {
        guard epoch >= self.epoch else { return }
        if epoch != self.epoch {
            self.epoch = epoch
            pending.removeAll(keepingCapacity: true)
        }
        pending.removeAll { $0.hasSameKey(as: change) }
        pending.append(change)
        if worker == nil { worker = Task { await drain() } }
    }

    /// Account teardown and normal quit must join persistence before reporting completion.
    /// Cancelling a caller cannot undo an entered write or discard a queued account clear.
    func flush() async {
        await worker?.value
    }

    private func drain() async {
        while !pending.isEmpty {
            let change = pending.removeFirst()
            await change.write(to: preferences)
        }
        worker = nil
    }
}
