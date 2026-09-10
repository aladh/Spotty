import Testing
import SpottyDomain
import Foundation

@Suite("Connect observation transactions")
struct ConnectObservationTests {
    private let now = Date(timeIntervalSince1970: 1_000)

    @Test
    func clusterCommitsRoutingAndPlaybackTogether() {
        var state = PlaybackState(accountEpoch: 1, engineEpoch: 2, session: .connecting)
        let observation = cluster(revision: 10, activeID: "phone", track: "spotify:track:a")
        #expect(PlaybackReducer.reduce(&state, envelope: observation))
        #expect(state.session == .ready)
        #expect(state.currentTrack?.uri == "spotify:track:a")
        #expect(state.devices.localDeviceID == "local")
        #expect(
            connectCommandRoute(owner: state.owner, localDeviceID: state.devices.localDeviceID)
                == .remote(from: "local", to: "phone"))
        #expect(state.devices.devices.first(where: \.isActive)?.id == "phone")
        #expect(state.sourceRevisions[.engineCluster] == 10)
        #expect(state.sourceRevisions[.enginePlayback] == 10)
        #expect(state.sourceRevisions[.engineConnection] == 10)
        #expect(state.sourceRevisions[.engineDevices] == 10)

        let accepted = state
        #expect(!PlaybackReducer.reduce(&state, envelope: cluster(revision: 9, activeID: "local", track: nil)))
        #expect(state == accepted)
    }

    @Test
    func newerLocalPlaybackSurvivesOlderClusterComponent() {
        var state = PlaybackState(accountEpoch: 1, engineEpoch: 2, session: .ready)
        #expect(
            PlaybackReducer.reduce(
                &state,
                envelope: PlaybackEventEnvelope(
                    accountEpoch: 1,
                    engineEpoch: 2,
                    source: .enginePlayback,
                    revision: 20,
                    receivedAt: now,
                    event: .enginePlayback(
                        EnginePlaybackSnapshot(
                            transport: .playing,
                            trackURI: "spotify:track:new",
                            timing: PlaybackTiming(position: 12, anchoredAt: now)
                        )
                    )
                )
            ))
        #expect(
            PlaybackReducer.reduce(
                &state, envelope: cluster(revision: 10, activeID: "local", track: "spotify:track:old")))
        #expect(state.currentTrack?.uri == "spotify:track:new")
        #expect(state.transport == .playing)
        #expect(state.timing.position == 12)
        #expect(state.sourceRevisions[.enginePlayback] == 20)
        #expect(state.devices.localDeviceID == "local")
        #expect(state.devices.devices.first(where: \.isActive)?.id == "local")
    }

    @Test
    func rejectedGenerationDoesNotConsumeAnyComponentRevision() {
        var state = PlaybackState(accountEpoch: 2, engineEpoch: 3, session: .ready)
        let before = state
        #expect(
            !PlaybackReducer.reduce(
                &state, envelope: cluster(revision: 100, activeID: "phone", track: "spotify:track:a")))
        #expect(state == before)
    }

    private func cluster(revision: UInt64, activeID: String, track: String?) -> PlaybackEventEnvelope {
        let devices = [
            PlaybackDevice(id: "local", name: "Spotty", type: "computer", isActive: activeID == "local"),
            PlaybackDevice(id: "phone", name: "Phone", type: "smartphone", isActive: activeID == "phone"),
        ]
        let owner = connectionPlaybackOwner(
            isLocalActive: activeID == "local",
            localDeviceID: "local",
            localDeviceName: "Spotty",
            devices: devices,
            currentTrackURI: track,
            previousOwner: .none,
            lastRemoteDeviceID: nil
        )
        return PlaybackEventEnvelope(
            accountEpoch: 1,
            engineEpoch: 2,
            source: .engineCluster,
            revision: revision,
            receivedAt: now,
            event: .engineCluster(
                EngineConnectSnapshot(
                    devices: PlaybackDeviceSnapshot(devices: devices, localDeviceID: "local", revision: revision),
                    connection: EngineConnectionSnapshot(session: .ready, owner: owner, localDeviceID: "local"),
                    connectionRevision: revision,
                    playback: EnginePlaybackSnapshot(
                        transport: .paused,
                        trackURI: track,
                        timing: PlaybackTiming(anchoredAt: now)
                    ),
                    playbackRevision: revision
                )
            )
        )
    }
}
