import Foundation

/// One cluster member as the engine observes it: identity and protobuf type name only.
/// Activity, sort, and unused Web API fields are not part of this row.
public struct ConnectProtocolDevice: Equatable, Sendable {
    public let id: String
    public let name: String
    public let type: String

    public init(id: String, name: String, type: String) {
        self.id = id
        self.name = name
        self.type = type
    }
}

/// App-facing Connect device list from unfiltered cluster members.
///
/// The cluster names one active device; members do not carry `is_active`. Empty
/// `activeDeviceID` means nothing is active anywhere and must clear activity.
public enum ConnectDeviceProjection: Sendable {
    /// A ready Mac is the default destination for a user-initiated play when Connect
    /// has no owner. This is selection, not protocol activation: opening the app
    /// must not transfer a session or start audio. Preserve identified remote candidates.
    public static func defaultLocalDevice(in state: PlaybackState) -> PlaybackDevice? {
        guard state.session == .ready, state.transport == .paused || state.transport == .stopped,
            let localID = state.devices.localDeviceID, !localID.isEmpty,
            !state.devices.devices.contains(where: \.isActive)
        else { return nil }
        switch state.owner {
        case .none, .uncertain(nil):
            return state.devices.devices.first { $0.id == localID }
        case .local, .remote, .uncertain(.some):
            return nil
        }
    }

    public static func isActive(deviceID: String, activeDeviceID: String) -> Bool {
        !activeDeviceID.isEmpty && deviceID == activeDeviceID
    }

    /// Wire type is an open enum. An empty name has no variant to report.
    public static func normalizedType(_ type: String) -> String {
        type.isEmpty ? "UNKNOWN" : type
    }

    public static func devices(
        from protocolDevices: [ConnectProtocolDevice],
        activeDeviceID: String
    ) -> [ConnectDevice] {
        protocolDevices
            .sorted { $0.id < $1.id }
            .map { device in
                ConnectDevice(
                    id: device.id,
                    name: device.name,
                    type: normalizedType(device.type),
                    isActive: isActive(deviceID: device.id, activeDeviceID: activeDeviceID)
                )
            }
    }
}
