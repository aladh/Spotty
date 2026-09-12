import Foundation

public nonisolated protocol PlaybackClock: Sendable {
    func now() -> Date
    func sleep(seconds: TimeInterval) async throws
}

public nonisolated struct SystemPlaybackClock: PlaybackClock {
    public init() {}

    public func now() -> Date { Date() }
    public func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}
