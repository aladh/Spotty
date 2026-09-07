import Testing
import SpottyDomain
import Foundation

@Suite("Idle Connect destination")
struct IdleConnectDestinationTests {
    @Test
    func localDefaultRequiresReadyIdleConnectAndPreservesRemoteOwnership() {
        let mac = PlaybackDevice(id: "mac", name: "Mac", type: "computer")
        let phone = PlaybackDevice(id: "phone", name: "Phone", type: "smartphone")
        var state = PlaybackState(
            session: .ready, owner: .uncertain(nil), transport: .paused,
            currentTrack: CurrentTrack(uri: "spotify:track:retained"),
            devices: PlaybackDeviceSnapshot(devices: [mac, phone], localDeviceID: "mac", revision: 1)
        )
        #expect(ConnectDeviceProjection.defaultLocalDevice(in: state) == mac)
        #expect(state.owner == .uncertain(nil), "selection must not invent protocol ownership")
        state.currentTrack = nil
        state.owner = .none
        #expect(ConnectDeviceProjection.defaultLocalDevice(in: state) == mac)
        for owner: PlaybackOwner in [.remote(phone), .uncertain(phone), .local(mac)] {
            state.owner = owner
            #expect(ConnectDeviceProjection.defaultLocalDevice(in: state) == nil)
        }
        state.owner = .uncertain(nil)
        state.transport = .playing
        #expect(ConnectDeviceProjection.defaultLocalDevice(in: state) == nil)
        state.transport = .buffering
        #expect(ConnectDeviceProjection.defaultLocalDevice(in: state) == nil)
        state.transport = .paused
        for phase: PlaybackSessionPhase in [.connecting, .recovering, .signedOut, .failed("test")] {
            state.session = phase
            #expect(ConnectDeviceProjection.defaultLocalDevice(in: state) == nil)
        }
        state.session = .ready
        state.devices = PlaybackDeviceSnapshot(devices: [phone], localDeviceID: "mac", revision: 2)
        #expect(ConnectDeviceProjection.defaultLocalDevice(in: state) == nil)
        state.devices = PlaybackDeviceSnapshot(devices: [mac], localDeviceID: nil, revision: 3)
        #expect(ConnectDeviceProjection.defaultLocalDevice(in: state) == nil)
        state.devices = PlaybackDeviceSnapshot(
            devices: [mac, PlaybackDevice(id: "phone", name: "Phone", type: "phone", isActive: true)],
            localDeviceID: "mac", revision: 4)
        #expect(ConnectDeviceProjection.defaultLocalDevice(in: state) == nil)
    }
}

@Suite("Connect device projection")
struct ConnectDeviceProjectionTests {
    @Test(arguments: ["", "TOASTER", "Unknown"])
    func testNormalizedType(_ type: String) {
        let expected = type.isEmpty ? "UNKNOWN" : type
        #expect(
            (ConnectDeviceProjection.normalizedType(type)) == (expected),
            "normalizing \(type.isEmpty ? "an empty" : "a named") type preserves the wire value")
    }

    @Test
    func testConnectDeviceProjection() {
        func proto(_ id: String, name: String, type: String) -> ConnectProtocolDevice {
            ConnectProtocolDevice(id: id, name: name, type: type)
        }

        do {
            #expect(
                (ConnectDeviceProjection.isActive(deviceID: "mac", activeDeviceID: "mac")) == true,
                "matching nonempty active id is active")
            #expect(
                (!ConnectDeviceProjection.isActive(deviceID: "mac", activeDeviceID: "phone")) == true,
                "a different device is not active")
            #expect(
                (!ConnectDeviceProjection.isActive(deviceID: "mac", activeDeviceID: "")) == true,
                "an empty active id clears activity")
            let projected = ConnectDeviceProjection.devices(
                from: [
                    proto("speaker", name: "Speaker", type: "Speaker"),
                    proto("mac", name: "Mac", type: "Computer"),
                    proto("unknown", name: "Odd", type: ""),
                ],
                activeDeviceID: "mac"
            )
            #expect((projected.map(\.id)) == (["mac", "speaker", "unknown"]), "projection sorts by id")
            #expect((projected[0].isActive) == (true), "active member is marked")
            #expect((projected[1].isActive) == (false), "other members stay inactive")
            #expect((projected[2].type) == ("UNKNOWN"), "empty type is UNKNOWN")
            #expect((projected[2].symbolName) == ("hifispeaker"), "unknown type uses the default icon")

            let noneActive = ConnectDeviceProjection.devices(
                from: [proto("mac", name: "Mac", type: "Computer")],
                activeDeviceID: ""
            )
            #expect(
                (noneActive.allSatisfy { !$0.isActive }) == true, "empty cluster active id clears the listed device")
        }
    }
}
