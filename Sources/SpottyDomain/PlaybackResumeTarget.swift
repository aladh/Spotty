/// An expectation for user resume, checked against the engine's own session observations.
/// This never authorizes a context load or a different track as a fallback.
public struct PlaybackResumeTarget: Equatable, Sendable {
    public let trackURI: String
    public let contextURI: String?
    public let positionMS: UInt32
    public let engineGeneration: UInt64

    public init(trackURI: String, contextURI: String?, positionMS: UInt32, engineGeneration: UInt64) {
        self.trackURI = trackURI
        self.contextURI = contextURI.flatMap { $0.isEmpty ? nil : $0 }
        self.positionMS = positionMS
        self.engineGeneration = engineGeneration
    }
}
