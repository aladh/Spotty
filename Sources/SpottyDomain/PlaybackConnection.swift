import Foundation

public enum PlaybackSessionPhase: Equatable, Sendable, Codable {
    case signedOut
    case authorizing
    case connecting
    case ready
    case recovering
    case failed(String)
}

public struct PlaybackDevice: Equatable, Sendable, Codable {
    public let id: String
    public let name: String
    public let type: String
    public let isActive: Bool

    public init(id: String, name: String, type: String, isActive: Bool = false) {
        self.id = id
        self.name = name
        self.type = type
        self.isActive = isActive
    }
}

public enum PlaybackOwner: Equatable, Sendable, Codable {
    case none
    case local(PlaybackDevice)
    case remote(PlaybackDevice)
    case uncertain(PlaybackDevice?)
}

/// Single owner-resolution policy for connection callbacks and device snapshots.
/// Metadata availability is not ownership: a URI is sufficient evidence that playback exists,
/// so labels and artwork may arrive later without changing where transport commands route.
/// `lastRemoteDeviceID` is immutable event context, never read from store preferences here.
/// A matching remembered remote remains an uncertain candidate so paused Connect playback stays
/// remote-routable; a missing, stale, or local identity fallback stays `uncertain(nil)` and
/// never becomes local.
public func connectionPlaybackOwner(
    isLocalActive: Bool,
    localDeviceID: String?,
    localDeviceName: String,
    devices: [PlaybackDevice],
    currentTrackURI: String?,
    previousOwner: PlaybackOwner,
    lastRemoteDeviceID: String?
) -> PlaybackOwner {
    if isLocalActive {
        let local =
            devices.first { $0.id == localDeviceID }
            ?? PlaybackDevice(
                id: localDeviceID ?? "",
                name: localDeviceName,
                type: "computer",
                isActive: true
            )
        return .local(local)
    }
    if let remote = devices.first(where: { $0.isActive && $0.id != localDeviceID }) {
        return .remote(remote)
    }
    guard currentTrackURI?.isEmpty == false else { return .none }

    let candidate: PlaybackDevice? =
        switch previousOwner {
        case let .remote(device), let .uncertain(.some(device)):
            devices.first { $0.id == device.id } ?? device
        default:
            lastRemoteDeviceID.flatMap { id in
                guard id != localDeviceID else { return nil }
                return devices.first { $0.id == id }
            }
        }
    return .uncertain(candidate)
}

/// Process-lifetime gate shared by termination handling and command admission.
public struct PlaybackTerminationGate: Sendable {
    public private(set) var hasBegun = false

    public init() {}

    @discardableResult
    public mutating func begin() -> Bool {
        guard !hasBegun else { return false }
        hasBegun = true
        return true
    }

    public var allowsCommands: Bool { !hasBegun }
}
