/// Ordered reconnect rehydration targets from sticky session context/track identity and position.
///
/// Empty strings are missing: that is how session globals and engine wire URIs read after
/// cleanup, not a URI Spirc can load. Capture these from resume-load FFI identity rather than
/// presentation snapshots.
/// A deactivation resume point outranks the live position. `LoadRequest` construction stays
/// in the engine; Swift iterates `targets()`.
public struct ResumeLoadPlan: Equatable, Sendable {
    public let positionMS: UInt32
    public let contextURI: String?
    /// Kept even when empty so a context load can still pass a track hint. Only the
    /// single-track fallback treats empty as missing.
    public let trackURI: String?

    public init(positionMS: UInt32, contextURI: String?, trackURI: String?) {
        self.positionMS = positionMS
        self.contextURI = Self.nonemptyURI(contextURI)
        self.trackURI = trackURI
    }

    public static func resumePosition(savedAtDeactivation: UInt32, live: UInt32) -> UInt32 {
        savedAtDeactivation > 0 ? savedAtDeactivation : live
    }

    public static func capture(
        savedAtDeactivation: UInt32,
        live: UInt32,
        contextURI: String?,
        trackURI: String?
    ) -> ResumeLoadPlan {
        ResumeLoadPlan(
            positionMS: resumePosition(savedAtDeactivation: savedAtDeactivation, live: live),
            contextURI: Self.nonemptyURI(contextURI),
            trackURI: trackURI
        )
    }

    public enum Target: Equatable, Sendable {
        case context(uri: String, trackHint: String?, positionMS: UInt32)
        case track(uri: String, positionMS: UInt32)
    }

    public func targets() -> [Target] {
        var targets: [Target] = []
        if let contextURI {
            targets.append(
                .context(uri: contextURI, trackHint: trackURI, positionMS: positionMS)
            )
        }
        if let trackURI = Self.nonemptyURI(trackURI) {
            targets.append(.track(uri: trackURI, positionMS: positionMS))
        }
        return targets
    }

    private static func nonemptyURI(_ uri: String?) -> String? {
        uri.flatMap { $0.isEmpty ? nil : $0 }
    }
}
