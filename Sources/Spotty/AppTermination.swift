import OSLog
import SpottyDiagnostics
import SpottyRuntimeContracts

/// Owns the app's single asynchronous quit reply, including the last-resort deadline.
@MainActor
final class AppTermination {
    private(set) var hasBegun = false
    private let clock: any PlaybackClock
    private var completion: (@MainActor () -> Void)?
    private var shutdownTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?

    init(clock: any PlaybackClock = SystemPlaybackClock()) {
        self.clock = clock
    }

    deinit {
        shutdownTask?.cancel()
        deadlineTask?.cancel()
    }

    func begin(
        shutdown: @escaping @MainActor () async -> Void,
        completion: @escaping @MainActor () -> Void
    ) {
        guard !hasBegun else { return }
        hasBegun = true
        self.completion = completion
        shutdownTask = Task { [weak self] in
            await shutdown()
            guard !Task.isCancelled else { return }
            SpottyLog.lifecycle.info("Application termination cleanup completed")
            self?.finish()
        }
        deadlineTask = Task { [weak self, clock] in
            // Engine cleanup has separate four-second Spirc and Dealer drains. The outer
            // deadline allows both, plus the bounded effect drain and scheduling margin.
            try? await clock.sleep(seconds: 10)
            guard !Task.isCancelled else { return }
            SpottyLog.lifecycle.warning("Application termination cleanup deadline expired")
            self?.finish()
        }
    }

    private func finish() {
        guard let completion else { return }
        self.completion = nil
        shutdownTask?.cancel()
        deadlineTask?.cancel()
        shutdownTask = nil
        deadlineTask = nil
        completion()
    }
}
