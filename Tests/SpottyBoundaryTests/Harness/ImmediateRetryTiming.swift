import Foundation
import SpottyDomain

extension SpotifyTransientRetry.Timing {
    /// Completes backoff without waiting. Injected by deterministic checks.
    static let immediate = Self(
        now: { Date(timeIntervalSince1970: 0) },
        sleep: { _ in try Task.checkCancellation() },
        unitJitter: { 1 }
    )
}
