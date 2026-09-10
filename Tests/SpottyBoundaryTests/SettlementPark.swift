import Foundation

/// A deterministic continuation gate for tests that need to hold an effect until cancellation,
/// replacement, or bounded draining has been observed.
@MainActor
final class SettlementPark {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isParked = false
    private(set) var didFinish = false

    func park() async {
        isParked = true
        await withCheckedContinuation { continuation = $0 }
        didFinish = true
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
