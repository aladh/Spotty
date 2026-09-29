import Foundation
import SpottyDomain
import Synchronization
@testable import SpottyGateway

func gatewayTokens(expiresAt: Date = .distantFuture) -> KeymasterTokens {
    KeymasterTokens(
        accessToken: "fixture-access", refreshToken: "fixture-refresh", expiresAt: expiresAt,
        username: "fixture-user")
}

/// Isolated, synchronized persistence used by gateway tests; never touches the live session file.
final class GatewayGrantStore: KeymasterTokenStoring, Sendable {
    enum Failure: Error, Equatable { case saveRejected }

    private struct State {
        var tokens: KeymasterTokens?
        var failSaves = false
        var clearCount = 0
        var saveCount = 0
    }
    private let state: Mutex<State>
    private let readOutcome: KeymasterGrantLoadResult?

    init(stored: KeymasterTokens? = nil, readOutcome: KeymasterGrantLoadResult? = nil, failSaves: Bool = false) {
        state = Mutex(State(tokens: stored, failSaves: failSaves))
        self.readOutcome = readOutcome
    }

    var saveCount: Int { state.withLock { $0.saveCount } }
    var clearCount: Int { state.withLock { $0.clearCount } }
    var stored: KeymasterTokens? { state.withLock { $0.tokens } }
    var failSaves: Bool {
        get { state.withLock { $0.failSaves } }
        set { state.withLock { $0.failSaves = newValue } }
    }

    func loadResult() -> KeymasterGrantLoadResult {
        readOutcome ?? state.withLock { $0.tokens.map(KeymasterGrantLoadResult.found) ?? .absent }
    }

    func save(_ tokens: KeymasterTokens) throws {
        try state.withLock {
            $0.saveCount += 1
            if $0.failSaves { throw Failure.saveRejected }
            $0.tokens = tokens
        }
    }

    func clear() {
        state.withLock {
            $0.clearCount += 1
            $0.tokens = nil
        }
    }
}

extension SpotifyTransientRetry.Timing {
    /// Completes backoff without waiting. Injected by deterministic checks.
    static let immediate = Self(
        now: { Date(timeIntervalSince1970: 0) },
        sleep: { _ in try Task.checkCancellation() },
        unitJitter: { 1 }
    )
}

enum GatewayFixtureFailure: Error { case unavailable }
