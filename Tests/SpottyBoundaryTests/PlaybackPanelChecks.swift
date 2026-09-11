import Testing
//
//  PlaybackPanelChecks.swift
//  Spotty
//

import Foundation
@testable import SpottyCore
import struct SpottyDomain.QueueProtocolTrack

@Suite("Playback Panel")
struct PlaybackPanelTests {
    @Test
    @MainActor
    func testPlaybackPanel() {
        // Interpolation, snapshot position, repeat flags, history policy, and queue
        // source labels are covered canonically in the domain suite; here only the
        // boundary-owned store projection and wire decoding are exercised.
        // Cold-start resolution: backend queue/state events carry uris without names,
        // so the bar's metadata must come from the loaded catalog.
        do {
            let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
            let metadata = CatalogMetadataRepository(
                attributesProvider: TrackAttributesAPI(),
                session: session
            )
            metadata.replaceTracks(
                [
                    CatalogTrack(
                        id: "a", uri: "spotify:track:liked", title: "Liked One", artist: "Artist L",
                        album: "Album", duration: 200, artworkURL: nil, addedAt: nil
                    )
                ], from: .library)
            metadata.replaceTracks(
                [
                    CatalogTrack(
                        id: "b", uri: "spotify:track:searched", title: "Searched One", artist: "Artist S",
                        album: "Album S", duration: 180, artworkURL: URL(string: "https://example/s.jpg"), addedAt: nil
                    )
                ], from: .search)
            metadata.replaceTracks(
                [
                    CatalogTrack(
                        id: "c", uri: "spotify:track:pl", title: "Playlist One", artist: "Artist P",
                        album: "Album P", duration: 150, artworkURL: nil, addedAt: nil
                    )
                ], from: .playlist)

            let liked = metadata.knownTrack(for: "spotify:track:liked")
            #expect((liked?.title) == ("Liked One"), "liked list resolves")
            let searched = metadata.knownTrack(for: "spotify:track:searched")
            #expect(
                (searched?.artworkURL?.absoluteString) == ("https://example/s.jpg"),
                "search results resolve with artwork")

            let info = metadata.displayInfo(for: "spotify:track:pl")
            #expect((info.title) == ("Playlist One"), "display info resolves the title")

            let unknown = metadata.displayInfo(for: "spotify:track:deadbeef")
            #expect((unknown.title) == ("Unknown track"), "unknown uris still name something")
            #expect((unknown.artist) == ("deadbeef"), "unknown uris surface their id")

            let homePlaylist = CatalogItem(
                id: "home-playlist",
                uri: "spotify:playlist:home",
                title: "Home Playlist",
                subtitle: "Listener",
                artworkURL: nil,
                kind: .playlist
            )
            metadata.replaceItems([homePlaylist], from: .home)
            #expect(
                (metadata.knownItem(for: homePlaylist.uri)?.title) == ("Home Playlist"),
                "home item lookup stays lazy and resolves")

            let queueWaitingForOrdering = SidePanelQueueRefreshIdentity(
                isConnected: true,
                currentTrackURI: "spotify:track:current",
                connectOrderingVersion: 0
            )
            let queueWithOrdering = SidePanelQueueRefreshIdentity(
                isConnected: true,
                currentTrackURI: "spotify:track:current",
                connectOrderingVersion: 1
            )
            #expect(
                (queueWaitingForOrdering != queueWithOrdering) == true,
                "launch-time queue ordering restarts metadata hydration")
            let queueAfterHydration = SidePanelQueueRefreshIdentity(
                isConnected: true,
                currentTrackURI: "spotify:track:current",
                connectOrderingVersion: queueWithOrdering.connectOrderingVersion
            )
            #expect((queueAfterHydration) == (queueWithOrdering), "queue hydration does not schedule a second refresh")
        }

        do {
            let now = Date(timeIntervalSince1970: 1_000_000)
            let store = PlaybackHistoryStore()
            store.notePlayed(uri: "spotify:track:a", title: "A", artist: "X", artworkURL: nil, playedAt: now)
            #expect((store.entries.first?.playedAt) == (now), "history store records the injected playedAt")
            store.notePlayed(
                uri: "spotify:track:a",
                title: "A",
                artist: "X",
                artworkURL: nil,
                playedAt: now.addingTimeInterval(60)
            )
            #expect((store.entries.count) == (1), "history store replay keeps a single row")
            #expect(
                (store.entries.first?.playedAt) == (now.addingTimeInterval(60)),
                "history store replay uses the later injected timestamp")
        }

        do {
            // DTO-shape smoke: current-track identity is uri/provider/uid, not catalog labels.
            // Upcoming presentation lives in the QueueProtocolProjection domain suite; wire
            // coverage is Rust layout/callback/getter tests.
            let decoded = RustQueueState(
                revision: 1,
                sessionGeneration: 1,
                track: RustQueueState.Item(
                    uri: "spotify:track:now",
                    provider: "context",
                    uid: "occ-now"
                ),
                protocolNextTracks: [],
                protocolPrevTracks: [],
                queueRevision: "",
                disallowSetQueue: false,
                disallowRemovingFromNextTracks: false
            )
            #expect((decoded.track?.uri) == ("spotify:track:now"), "current track keeps identity")
            #expect((decoded.track?.provider) == ("context"), "current track keeps provider")
            #expect((decoded.track?.uid) == ("occ-now"), "current track keeps uid")

            let devicesJSON = """
                [{"id":"abc123","name":"Living Room","type":"speaker","is_active":false,
                  "is_private_session":false,"is_restricted":false,"volume_percent":40,"disable_volume":false},
                 {"id":"def456","name":"Mac","type":"Computer","is_active":true,
                  "is_private_session":false,"is_restricted":false,"volume_percent":null,"disable_volume":false}]
                """
            do {
                let devices = try JSONDecoder().decode([ConnectDevice].self, from: Data(devicesJSON.utf8))
                #expect((devices.count) == (2), "device list decodes")
                #expect((devices.first(where: \.isActive)?.name) == ("Mac"), "active device is named")
                #expect((devices.first?.symbolName) == ("hifispeaker"), "type maps to an icon")
            } catch {
                #expect((false) == true, "devices decode: \(error)")
            }

            // Spotify spells device types in mixed case; icon lookup must not.
            let casedTypesJSON = """
                [{"id":"t1","name":"Den","type":"TV","is_active":false},
                 {"id":"t2","name":"Phone","type":"SMARTPHONE","is_active":false}]
                """
            do {
                let cased = try JSONDecoder().decode([ConnectDevice].self, from: Data(casedTypesJSON.utf8))
                #expect((cased.first?.symbolName) == ("tv"), "tv type maps regardless of case")
                #expect((cased.last?.symbolName) == ("iphone"), "phone type maps regardless of case")
            } catch {
                #expect((false) == true, "cased device types decode: \(error)")
            }
        }

        do {
            let json = """
                {"currently_playing":null,"queue":[
                  {"id":"track-id","uri":"spotify:track:track-id","name":"First Track",
                   "duration_ms":123000,"artists":[{"name":"First Artist"}],
                   "album":{"name":"First Album","images":[
                     {"url":"https://example.com/small.jpg","width":64,"height":64},
                     {"url":"https://example.com/large.jpg","width":640,"height":640}
                   ]}},
                  {"id":"episode-id","uri":"spotify:episode:episode-id","name":"An Episode",
                   "duration_ms":456000,"show":{"name":"A Show","publisher":"A Publisher","images":[]}}
                ]}
                """
            do {
                let tracks = try SpotifyWebPlayerAPI.decodeQueue(Data(json.utf8))
                #expect(
                    (tracks.map(\.uri))
                        == ([
                            "spotify:track:track-id", "spotify:episode:episode-id",
                        ]), "documented queue preserves order")
                #expect((tracks.first?.artist) == ("First Artist"), "queue track decodes its artist")
                #expect((tracks.first?.album) == ("First Album"), "queue track decodes its album")
                #expect(
                    (tracks.first?.artworkURL?.absoluteString) == ("https://example.com/large.jpg"),
                    "queue track chooses the largest artwork")
                #expect((tracks.last?.artist) == ("A Publisher"), "queue episode decodes its publisher")
            } catch {
                #expect((false) == true, "documented queue decodes: \(error)")
            }
        }

        do {
            do {
                let encoded = try JSONEncoder().encode(SpotifyConnectCommand.seek(to: 12_345))
                let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
                #expect((object?["endpoint"] as? String) == ("seek_to"), "seek endpoint is encoded")
                #expect((object?["value"] as? Int) == (12_345), "seek position is encoded")

                let shuffle = try JSONEncoder().encode(SpotifyConnectCommand.shuffle(true))
                let shuffleObject = try JSONSerialization.jsonObject(with: shuffle) as? [String: Any]
                #expect((shuffleObject?["value"] as? Bool) == (true), "shuffle boolean is encoded")

                let add = try JSONEncoder().encode(SpotifyConnectCommand.addToQueue("spotify:track:abc"))
                let addObject = try JSONSerialization.jsonObject(with: add) as? [String: Any]
                let track = addObject?["track"] as? [String: Any]
                #expect((addObject?["endpoint"] as? String) == ("add_to_queue"), "queue endpoint is encoded")
                #expect((track?["uri"] as? String) == ("spotify:track:abc"), "queued track uri is encoded")
                #expect((addObject?["next_tracks"]) == nil, "add_to_queue does not encode next_tracks")

                let setQueue = try JSONEncoder().encode(
                    SpotifyConnectCommand.setQueue(
                        next: [QueueProtocolTrack(uri: "spotify:track:keep", uid: "q0", provider: "queue")],
                        prev: [QueueProtocolTrack(uri: "spotify:track:prev", uid: "p0", provider: "context")],
                        queueRevision: "rev-1"
                    )
                )
                let setObject = try JSONSerialization.jsonObject(with: setQueue) as? [String: Any]
                #expect((setObject?["endpoint"] as? String) == ("set_queue"), "set_queue endpoint is encoded")
                #expect(
                    (((setObject?["prev_tracks"] as? [[String: Any]])?.first?["uri"] as? String))
                        == ("spotify:track:prev"),
                    "set_queue preserves prev_tracks")
            } catch {
                #expect((false) == true, "Connect commands encode: \(error)")
            }
        }
    }
}
