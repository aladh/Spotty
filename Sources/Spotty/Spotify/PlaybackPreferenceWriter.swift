import Foundation

/// Submission happens synchronously on the store's actor. Each write waits for its predecessor,
/// including a noncooperative write already in progress when logout advances the account epoch.
@MainActor
final class PlaybackPreferenceWriter {
    private let preferences: any PlaybackPreferences
    private var epoch: UInt64 = 0
    private var tail: Task<Void, Never>?

    init(preferences: any PlaybackPreferences) { self.preferences = preferences }

    @discardableResult
    func submit(epoch: UInt64, _ write: @escaping @Sendable (any PlaybackPreferences) async -> Void) -> Task<
        Void, Never
    > {
        self.epoch = max(self.epoch, epoch)
        let previous = tail
        let task = Task { [self] in
            await previous?.value
            guard epoch == self.epoch else { return }
            await write(preferences)
        }
        tail = task
        return task
    }
}
