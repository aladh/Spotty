/// Serializes start/stop so a superseded stop cannot tear down a later start.
///
/// `beginStop` clears rendering on the caller thread (so a parked writer can drop) and returns
/// the generation that the serialized AV teardown must still match. `beginStart` bumps the
/// generation so an in-flight stop becomes a no-op.
public struct AudioOutputControlEpoch: Equatable, Sendable {
    public private(set) var isRendering = false
    public private(set) var generation: UInt64 = 0

    public init() {}

    public mutating func beginStart() {
        isRendering = true
        generation &+= 1
    }

    public mutating func beginStop() -> UInt64? {
        guard isRendering else { return nil }
        isRendering = false
        return generation
    }

    public func shouldApplyStop(_ captured: UInt64) -> Bool {
        !isRendering && generation == captured
    }
}
