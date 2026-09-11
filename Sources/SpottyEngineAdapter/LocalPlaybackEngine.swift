import Foundation
import SpottyDomain

public nonisolated struct PlaybackEngineResult: Equatable, Sendable {
    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    public static let ok = PlaybackEngineResult(rawValue: 0)
    public static let error = PlaybackEngineResult(rawValue: -1)
    /// Initialization proved that the cached streaming credential is unusable. This terminal
    /// result keeps the Web API grant intact while the account owner requests fresh authorization.
    public static let credentialsRejected = PlaybackEngineResult(rawValue: -4)
    public var isOK: Bool { rawValue == 0 }
    public var isCredentialsRejected: Bool { rawValue == Self.credentialsRejected.rawValue }
    public var requiresReconnect: Bool { rawValue == -2 || rawValue == -3 }
}

/// One ordered resume-load sequence for user resume and reconnect rehydration.
///
/// User resume plays first and, on a non-reconnect failure, tries each target until one
/// lands. Reconnect rehydration passes no `play`: the engine has already activated and is
/// holding readiness open, and inside that window a load returns as soon as it is queued, so
/// the sequence stops at the first queued target exactly as the engine's own loop used to.
/// A reconnect-required result ends the sequence either way. No targets is an ordinary
/// failure; the engine's window then times out on its own.
public nonisolated enum ResumeLoadSequence {
    public static func completing(
        play: PlaybackEngineResult?,
        targets: [ResumeLoadPlan.Target],
        load: (ResumeLoadPlan.Target) -> PlaybackEngineResult
    ) -> PlaybackEngineResult {
        if let play, play.isOK || play.requiresReconnect { return play }
        for target in targets {
            let loaded = load(target)
            if loaded.isOK || loaded.requiresReconnect { return loaded }
        }
        return play ?? .error
    }
}

public nonisolated enum LocalPlaybackOperation: Sendable {
    case playURI(String)
    case playTracks([String])
    case pause
    case resume(ResumeLoadPlan)
    /// Engine reconnect published `resume_pending` for `sessionGeneration`; issue the plan's
    /// loads without `play()`. The engine runs them only while that session and window last.
    case rehydrate(ResumeLoadPlan, sessionGeneration: UInt64)
    case next
    case previous
    case seek(UInt32)
    case shuffle(Bool)
    case repeatOptions(RepeatTransitionPlan)
    case addToQueue(String)
    case transferToLocal
    case transferToDevice(String)
}

public nonisolated protocol LocalPlaybackEngine: Sendable {
    func events() -> AsyncStream<RustPlaybackEventEnvelope>
    func authorizeStreaming(with accessToken: String) -> Int32
    func initialize() -> PlaybackEngineResult
    func execute(_ operation: LocalPlaybackOperation) -> PlaybackEngineResult
    func positionMilliseconds() -> UInt32
    func resumePositionMilliseconds() -> UInt32
    func resumeContextURI() -> String?
    func resumeTrackURI() -> String?
    func queueSnapshot() -> RustQueueState?
    func shutdown() -> PlaybackEngineResult
    func cleanup()
    func clearStreamingCredentials()
    func disconnect() -> PlaybackEngineResult
    func forceReconnect() -> Int32
}

extension LocalPlaybackEngine {
    public func resumePositionMilliseconds() -> UInt32 { 0 }
    public func resumeContextURI() -> String? { nil }
    public func resumeTrackURI() -> String? { nil }
    public func queueSnapshot() -> RustQueueState? { nil }
}

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
