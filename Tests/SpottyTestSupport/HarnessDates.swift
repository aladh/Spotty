import Foundation

/// Fixed instants shared by every boundary fake. A single epoch keeps anchored timings comparable
/// across checks that mix a store, a feedback presenter, and a clock.
public enum HarnessDates {
    /// The instant every sticky harness clock reports.
    public static let fixed = Date(timeIntervalSince1970: 1_800_000_000)
}
