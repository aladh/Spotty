import Foundation
import SpottyEngineAdapter

/// Operational failures for playback *commands* at the coordinator/store boundary.
///
/// `Error` is required by `Result`'s `Failure` bound. Command methods still return these
/// cases in `Result` and throw only `CancellationError`. Infrastructure codes stay in
/// `PlaybackEngineResult`.
nonisolated enum PlaybackCommandFailure: Error, Equatable, Sendable {
    /// The local engine declined the command without invalidating the session.
    case rejected
    /// The local session must be reinitialized before another local command can succeed.
    case reconnectRequired
    /// The remote Connect client rejected or failed the command.
    case remoteRejected
    /// The local engine returned an unrecognized result.
    case unavailable

    static func from(engineResult: PlaybackEngineResult) -> Result<Void, PlaybackCommandFailure> {
        if engineResult.isOK {
            return .success(())
        }
        if engineResult.requiresReconnect {
            return .failure(.reconnectRequired)
        }
        if engineResult == .error {
            return .failure(.rejected)
        }
        return .failure(.unavailable)
    }
}
