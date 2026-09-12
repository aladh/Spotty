import Foundation
import SpottyRuntimeContracts
import SpottyDomain

// Live scheduling belongs to the adapter; the domain receives an explicit Timing value.
extension SpotifyTransientRetry.Timing {
    public static let production = Self(
        now: { Date() },
        sleep: { seconds in
            guard seconds > 0 else { return }
            try await Task.sleep(for: .seconds(seconds))
        },
        unitJitter: { Double.random(in: 0...1) }
    )
}
