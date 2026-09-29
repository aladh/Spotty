import Foundation
import Observation

/// Kind of a single transient mutation-feedback message.
///
/// Success, informational, and failure share one owner so playlist and queue
/// actions can report completion without a second banner or an event bus.
enum TransientFeedbackKind: Equatable, Sendable {
    case success
    case informational
    case failure
}

/// The one currently visible mutation-feedback message, if any.
struct TransientFeedbackMessage: Equatable, Identifiable, Sendable {
    let id: UInt64
    let kind: TransientFeedbackKind
    let text: String
}

/// App-composed owner for user-initiated mutation success, informational, and
/// failure feedback. At most one message is current; a newer presentation
/// cancels the previous automatic dismissal. Timing uses the injected clock so
/// checks never need a real sleep.
///
/// This is presentation-only. It is not reducer-owned playback state, durable
/// connection status, or a generic notification center.
@MainActor
@Observable
final class TransientFeedbackPresenter {
    static let defaultDuration: TimeInterval = 4

    private(set) var message: TransientFeedbackMessage?

    @ObservationIgnored private let clock: any PlaybackClock
    @ObservationIgnored private let duration: TimeInterval
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var dismissal: Task<Void, Never>?

    init(clock: any PlaybackClock, duration: TimeInterval = defaultDuration) {
        self.clock = clock
        self.duration = duration
    }

    deinit { dismissal?.cancel() }

    func success(_ text: String) {
        present(.success, text)
    }

    func informational(_ text: String) {
        present(.informational, text)
    }

    func failure(_ text: String) {
        present(.failure, text)
    }

    /// Cancels automatic dismissal and clears whatever is currently shown.
    func dismiss() {
        dismissal?.cancel()
        dismissal = nil
        message = nil
    }

    private func present(_ kind: TransientFeedbackKind, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        generation &+= 1
        let token = generation
        dismissal?.cancel()
        message = TransientFeedbackMessage(id: token, kind: kind, text: trimmed)
        dismissal = Task { [weak self, clock, duration] in
            do {
                try await clock.sleep(seconds: duration)
            } catch {
                // Cooperative cancellation leaves the current message. A
                // replacement already installed a newer token, so this path
                // must not clear it.
                return
            }
            self?.clearIfCurrent(token)
        }
    }

    /// Token-guarded clear so a late or uncooperative dismissal cannot remove a
    /// replacement message even if cancellation of the previous task is ignored.
    private func clearIfCurrent(_ token: UInt64) {
        guard message?.id == token else { return }
        message = nil
        dismissal = nil
    }
}
