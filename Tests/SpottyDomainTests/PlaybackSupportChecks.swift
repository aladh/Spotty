import Testing
import SpottyDomain
import Foundation

@Suite("Playback Support")
struct PlaybackSupportTests {
    @Test
    func interpolatedPositionAdvancesOnlyWhilePlaying() {
        let anchorDate = Date(timeIntervalSince1970: 1_000)
        #expect(
            (interpolatedPlaybackPosition(
                anchor: 40, anchoredAt: anchorDate, now: anchorDate.addingTimeInterval(0.25), isPlaying: true,
                duration: 200)) == (40.25), "playing advances between backend samples")
        #expect(
            (interpolatedPlaybackPosition(
                anchor: 40, anchoredAt: anchorDate, now: anchorDate.addingTimeInterval(10), isPlaying: false,
                duration: 200)) == (40), "paused position stays anchored")
        #expect(
            (interpolatedPlaybackPosition(
                anchor: 199.8, anchoredAt: anchorDate, now: anchorDate.addingTimeInterval(1), isPlaying: true,
                duration: 200)) == (200), "interpolation stops at track duration")
        #expect(
            (interpolatedPlaybackPosition(
                anchor: 40, anchoredAt: anchorDate, now: anchorDate.addingTimeInterval(-1), isPlaying: true,
                duration: 200)) == (40), "clock reversal cannot move the playhead backward")

        let receivedAt = Date(timeIntervalSince1970: 1_010)
        #expect(
            (playbackSnapshotPosition(
                positionMilliseconds: 40_000, durationMilliseconds: 200_000, timestampMilliseconds: 1_005_000,
                isPlaying: true, now: receivedAt)) == (45),
            "playing Connect snapshots compensate for their timestamp")
        #expect(
            (playbackSnapshotPosition(
                positionMilliseconds: 40_000, durationMilliseconds: 200_000, timestampMilliseconds: 1_005_000,
                isPlaying: false, now: receivedAt)) == (40), "paused Connect snapshots stay at their exact position"
        )
    }

    @Test
    func repeatModeCyclesAndMapsToBackendFlags() {
        let cycle: [RepeatMode] = [.off, .context, .track, .off]
        for (before, after) in zip(cycle, cycle.dropFirst()) {
            #expect((before.next) == (after), "cycle \(before) → \(after)")
        }
        #expect(
            (RepeatMode.context.flags) == (RepeatFlags(context: true, track: false)),
            "backend flags for context repeat"
        )
        #expect(
            (RepeatMode.track.flags) == (RepeatFlags(context: false, track: true)), "backend flags for track repeat"
        )
        #expect(
            (RepeatMode.off.flags) == (RepeatFlags(context: false, track: false)), "backend flags for no repeat")
        #expect((RepeatMode(context: true, track: false)) == (.context), "flags rebuild to context")
        #expect((RepeatMode(context: true, track: true)) == (.track), "track flag wins over context")
        #expect((RepeatMode(context: false, track: false)) == (.off), "flags rebuild to off")

        let offToContext = RepeatTransitionPlan.planning(from: RepeatMode.off.flags, to: RepeatMode.context.flags)
        #expect(
            (offToContext.mutations) == ([RepeatFlagMutation(flag: .context, enabled: true)]),
            "off → context sends only context on")
        #expect((offToContext.compensation) == ([]), "off → context has no compensation")

        let contextToTrack = RepeatTransitionPlan.planning(
            from: RepeatMode.context.flags, to: RepeatMode.track.flags)
        #expect(
            (contextToTrack.mutations)
                == ([
                    RepeatFlagMutation(flag: .context, enabled: false),
                    RepeatFlagMutation(flag: .track, enabled: true),
                ]), "context → track sends context off then track on")
        #expect(
            (contextToTrack.compensation) == ([RepeatFlagMutation(flag: .context, enabled: true)]),
            "context → track compensates the accepted context flag")

        let trackToOff = RepeatTransitionPlan.planning(from: RepeatMode.track.flags, to: RepeatMode.off.flags)
        #expect(
            (trackToOff.mutations) == ([RepeatFlagMutation(flag: .track, enabled: false)]),
            "track → off sends only track off")
        #expect((trackToOff.compensation) == ([]), "track → off has no compensation")
        #expect(
            (RepeatTransitionPlan.planning(from: RepeatMode.off.flags, to: RepeatMode.off.flags).mutations) == ([]),
            "identical flags send nothing")

        let bothTrue = RepeatFlags(context: true, track: true)
        #expect((RepeatMode(context: true, track: true)) == (.track), "both-true flags still display as track")
        #expect(
            (RepeatMode.track.flags) == (RepeatFlags(context: false, track: true)),
            "display track flags are not a both-true pair")
        #expect(
            (RepeatTransitionPlan.planning(from: bothTrue, to: RepeatMode.off.flags).mutations)
                == ([
                    RepeatFlagMutation(flag: .context, enabled: false),
                    RepeatFlagMutation(flag: .track, enabled: false),
                ]), "both-true track → off sends both flags off")
        #expect(
            (RepeatTransitionPlan.planning(from: RepeatMode.track.flags, to: RepeatMode.off.flags).mutations)
                == ([RepeatFlagMutation(flag: .track, enabled: false)]),
            "ordinary track → off still sends only track off")
        #expect(
            (bothTrue.applying(RepeatFlagMutation(flag: .context, enabled: false)))
                == (RepeatFlags(context: false, track: true)),
            "both-true first mutation is the compensated intermediate pair")
    }

    @Test
    func playbackHistoryKeepsTheNewestPlayPerTrack() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var entries = PlaybackHistory.updated(
            [], afterPlaying: "spotify:track:a", title: "A", artist: "X", artworkURLString: nil, playedAt: now)
        #expect((entries.first?.uri) == ("spotify:track:a"), "newest entry lands first")

        entries = PlaybackHistory.updated(
            entries, afterPlaying: "spotify:track:a", title: "A", artist: "X", artworkURLString: nil,
            playedAt: now.addingTimeInterval(60))
        #expect((entries.count) == (1), "replay does not duplicate")
        #expect((entries.first?.playedAt) == (now.addingTimeInterval(60)), "replay refreshes the timestamp")

        entries = PlaybackHistory.withMetadata(
            entries, for: "spotify:track:a", title: "Real Title", artist: "Real Artist",
            artworkURLString: "https://example/a.jpg")
        #expect((entries.first?.title) == ("Real Title"), "late metadata fills the title")
        #expect((entries.first?.playedAt) == (now.addingTimeInterval(60)), "late metadata keeps other fields")

        entries = (0..<PlaybackHistory.cap + 25).reversed().reduce(entries) { current, index in
            PlaybackHistory.updated(
                current, afterPlaying: "spotify:track:\(index)", title: "T\(index)", artist: "",
                artworkURLString: nil,
                playedAt: now.addingTimeInterval(TimeInterval(index)))
        }
        #expect((entries.count) == (PlaybackHistory.cap), "history is capped")

        var capped: [HistoryEntry] = []
        for index in 0..<PlaybackHistory.cap {
            capped = PlaybackHistory.updated(
                capped, afterPlaying: "spotify:track:t\(index)", title: "T\(index)", artist: "",
                artworkURLString: nil,
                playedAt: now.addingTimeInterval(TimeInterval(index)))
        }
        capped = PlaybackHistory.updated(
            capped, afterPlaying: "spotify:track:new", title: "New", artist: "", artworkURLString: nil,
            playedAt: now.addingTimeInterval(999))
        #expect((capped.count) == (PlaybackHistory.cap), "cap boundary stays at the cap")
        #expect((capped.first?.uri) == ("spotify:track:new"), "the new track lands on top")
        #expect((capped.last?.uri) == ("spotify:track:t1"), "exactly the oldest row falls off")

        var lifted: [HistoryEntry] = []
        for suffix in ["a", "b", "c"] {
            lifted = PlaybackHistory.updated(
                lifted, afterPlaying: "spotify:track:\(suffix)", title: suffix.uppercased(), artist: "",
                artworkURLString: nil, playedAt: now)
        }
        lifted = PlaybackHistory.updated(
            lifted, afterPlaying: "spotify:track:a", title: "A", artist: "", artworkURLString: nil,
            playedAt: now.addingTimeInterval(30))
        #expect((lifted.first?.uri) == ("spotify:track:a"), "a buried replay moves to the front")
        #expect((lifted.count) == (3), "the lift does not duplicate")
        #expect((lifted.last?.uri) == ("spotify:track:b"), "the other rows keep their order")

        let untouched = [
            HistoryEntry(
                uri: "spotify:track:kept", title: "Kept", artist: "K", artworkURLString: nil, playedAt: now)
        ]
        let afterMiss = PlaybackHistory.withMetadata(
            untouched, for: "spotify:track:other", title: "X", artist: "Y",
            artworkURLString: "https://example/x.jpg")
        #expect((afterMiss) == (untouched), "metadata for an absent uri changes nothing")

        let owned = [
            HistoryEntry(
                uri: "spotify:track:a", title: "A", artist: "X", artworkURLString: "https://example/old.jpg",
                playedAt: now)
        ]
        let enriched = PlaybackHistory.withMetadata(
            owned, for: "spotify:track:a", title: "Better Title", artist: "X",
            artworkURLString: "https://example/new.jpg")
        #expect(
            (enriched.first?.artworkURLString) == ("https://example/old.jpg"), "known artwork survives enrichment")
        #expect((enriched.first?.title) == ("Better Title"), "non-empty titles still update")
    }

    @Test
    func queueEntriesLabelTheirProviderAndKeepDistinctIdentities() {
        let queued = QueueEntry(uri: "spotify:track:a", provider: "queue")
        let suggested = QueueEntry(uri: "spotify:track:b", provider: "autoplay")
        let contextual = QueueEntry(uri: "spotify:track:c", provider: "context")
        let documented = QueueEntry(uri: "spotify:track:d", provider: "web-api")
        #expect(
            (queued.sourceLabel == "From your queue"
                && suggested.sourceLabel == "Suggested by Spotify"
                && contextual.sourceLabel == "From the current context"
                && documented.sourceLabel == "Up next") == true, "providers map to listener labels")
        let repeated = [
            QueueEntry(uri: "spotify:track:a", provider: "queue", occurrence: 0),
            QueueEntry(uri: "spotify:track:a", provider: "queue", occurrence: 1),
        ]
        #expect((repeated[0].id != repeated[1].id) == true, "duplicate queue tracks have distinct row identities")
        #expect((repeated.map(\.occurrence)) == ([0, 1]), "duplicate queue tracks keep typed occurrences")
        let uidBacked = QueueEntry(
            uri: "spotify:track:a", provider: "queue", occurrence: 7, uid: "occurrence-uid"
        )
        #expect(uidBacked.occurrence == 7)
        #expect(uidBacked.uid == "occurrence-uid")
        #expect(uidBacked.id == "uid-occurrence-uid-queue-spotify:track:a")
        #expect(
            (repeated[1].id)
                == (QueueEntry.identity(
                    occurrence: repeated[1].occurrence,
                    provider: repeated[1].provider,
                    uri: repeated[1].uri,
                    uid: ""
                )), "an empty uid stays out of selectable identity")

        let local = ConnectDevice(id: "local", name: "Spotty", type: "computer", isActive: false)
        let remote = ConnectDevice(id: "phone", name: "Phone", type: "smartphone", isActive: true)
        #expect(
            (local.displayName(localDeviceID: "local")) == ("This Mac"),
            "local device is identified even while inactive")
        #expect(
            (remote.displayName(localDeviceID: "local")) == ("Phone (Playing)"),
            "active remote device is identified as playing")
        #expect(
            (connectCommandRoute(isLocalActive: false, localDeviceID: "local", devices: [local, remote]))
                == (.remote(from: "local", to: "phone")), "transport routes to the active remote device")
        #expect(
            (connectCommandRoute(isLocalActive: false, localDeviceID: nil, devices: [remote]))
                == (.waitingForLocalIdentity), "remote commands wait for this device identity")
        #expect(
            (connectCommandRoute(isLocalActive: false, localDeviceID: "local", devices: [local])) == (.local),
            "no active remote keeps local playback available")
        #expect(
            (connectCommandRoute(
                isLocalActive: false,
                localDeviceID: "local",
                devices: [local, ConnectDevice(id: "phone", name: "Phone", type: "smartphone", isActive: false)],
                fallbackRemoteDeviceID: "phone"
            )) == (.remote(from: "local", to: "phone")), "paused playback retains its remote command target")
        let remoteOwner = PlaybackDevice(id: "phone", name: "Phone", type: "smartphone")
        #expect(
            (connectCommandRoute(owner: .remote(remoteOwner), localDeviceID: "local"))
                == (.remote(from: "local", to: "phone")), "explicit remote ownership routes remotely")
        #expect(
            (connectCommandRoute(owner: .uncertain(remoteOwner), localDeviceID: "local"))
                == (.remote(from: "local", to: "phone")), "an uncertain paused remote remains routable")
        #expect(
            (connectCommandRoute(owner: .uncertain(nil), localDeviceID: "local")) == (.needsDeviceSelection),
            "an unidentified owner cannot accidentally steal playback")

        #expect(
            connectCommandRoute(owner: .uncertain(nil), localDeviceID: nil) == .waitingForLocalIdentity,
            "a missing local identity still represents startup")
        #expect(
            connectCommandRoute(owner: .uncertain(nil), localDeviceID: "") == .waitingForLocalIdentity,
            "an empty local identity still represents startup")
        let freshMac = PlaybackDevice(id: "local", name: "Mac", type: "computer")
        let unownedTrack = connectionPlaybackOwner(
            isLocalActive: false, localDeviceID: "local", localDeviceName: "Mac",
            devices: [freshMac], currentTrackURI: "spotify:track:paused",
            previousOwner: .none, lastRemoteDeviceID: nil)
        #expect(connectCommandRoute(owner: unownedTrack, localDeviceID: "local") == .needsDeviceSelection)
        let selectedMac = connectionPlaybackOwner(
            isLocalActive: true, localDeviceID: "local", localDeviceName: "Mac",
            devices: [freshMac], currentTrackURI: "spotify:track:paused",
            previousOwner: unownedTrack, lastRemoteDeviceID: nil)
        #expect(connectCommandRoute(owner: selectedMac, localDeviceID: "local") == .local)

        let inactivePhone = PlaybackDevice(
            id: "phone",
            name: "Phone",
            type: "smartphone",
            isActive: false
        )
        let metadataLateOwner = connectionPlaybackOwner(
            isLocalActive: false,
            localDeviceID: "local",
            localDeviceName: "Spotty",
            devices: [PlaybackDevice(id: "local", name: "Spotty", type: "computer"), inactivePhone],
            currentTrackURI: "spotify:track:metadata-late",
            previousOwner: .none,
            lastRemoteDeviceID: "phone"
        )
        #expect(
            (metadataLateOwner) == (.uncertain(inactivePhone)),
            "a metadata-late remote track retains an uncertain remote identity")
        #expect(
            (connectCommandRoute(owner: metadataLateOwner, localDeviceID: "local"))
                == (.remote(from: "local", to: "phone")),
            "the metadata-late owner routes remotely instead of stealing playback")
        let missingFallbackOwner = connectionPlaybackOwner(
            isLocalActive: false,
            localDeviceID: "local",
            localDeviceName: "Spotty",
            devices: [PlaybackDevice(id: "local", name: "Spotty", type: "computer"), inactivePhone],
            currentTrackURI: "spotify:track:paused",
            previousOwner: .none,
            lastRemoteDeviceID: "missing-speaker"
        )
        #expect((missingFallbackOwner) == (.uncertain(nil)), "a stale last-remote fallback stays unidentified")
        #expect(
            (connectCommandRoute(owner: missingFallbackOwner, localDeviceID: "local"))
                == (.needsDeviceSelection),
            "an unidentified fallback cannot steal playback locally")
        let localIdentityFallback = connectionPlaybackOwner(
            isLocalActive: false,
            localDeviceID: "local",
            localDeviceName: "Spotty",
            devices: [PlaybackDevice(id: "local", name: "Spotty", type: "computer"), inactivePhone],
            currentTrackURI: "spotify:track:paused",
            previousOwner: .none,
            lastRemoteDeviceID: "local"
        )
        #expect(
            (localIdentityFallback) == (.uncertain(nil)),
            "a last-remote identity that matches this Mac stays unidentified")

        #expect(
            (queueBootstrapMetadataURI(
                snapshotTrackURI: "spotify:track:old",
                currentTrackURI: "spotify:track:new"
            )) == nil, "a cached queue for an older track cannot replace playback identity")
        #expect(
            (queueBootstrapMetadataURI(
                snapshotTrackURI: "spotify:track:new",
                currentTrackURI: "spotify:track:new"
            )) == ("spotify:track:new"), "a cached queue may enrich only the matching current track")
    }

    @Test
    func audioOutputControlEpochSerializesStartAndStop() {
        var epoch = AudioOutputControlEpoch()
        #expect((epoch.beginStop() == nil) == (true), "stop is a no-op before start")

        epoch.beginStart()
        let first = epoch.beginStop()
        #expect((first == 1) == true, "stop captures the live generation")
        #expect((!epoch.isRendering) == true, "rendering is cleared before serialized teardown")
        #expect(
            (first.map { epoch.shouldApplyStop($0) } == true) == true, "a stop still applies before a later start")

        epoch.beginStart()
        #expect((epoch.isRendering) == true, "rendering is live after start")
        #expect(
            (first.map { epoch.shouldApplyStop($0) } == false) == true,
            "a superseded stop cannot tear down a later start")
        #expect((epoch.generation) == (2), "start bumps the generation")

        let second = epoch.beginStop()
        #expect((second == 2) == true, "a new stop captures the new generation")
        #expect((second.map { epoch.shouldApplyStop($0) } == true) == true, "the new stop still applies")
        #expect((first.map { epoch.shouldApplyStop($0) } == false) == true, "the old stop remains inert")
    }
}
