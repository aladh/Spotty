import Testing
import SpottyDomain
import Foundation
@testable import SpottyCore
@testable import SpottyEngineAdapter
@testable import SpottySessionRuntime
@testable import SpottyGateway
import SpottyRuntimeContracts

/// Parks `libraryAlbums`/`libraryArtists` reads for `HarnessCatalog.onLibraryAlbums`/
/// `onLibraryArtists` closures. `HarnessCatalog` has no built-in notion of an overlapping in-flight
/// library read, so this small gate composes with it instead of hand-rolling a whole
/// `CatalogProviding` fake.
private actor LibraryParkGate {
    private var albumContinuation: CheckedContinuation<[PathfinderAlbum], Never>?
    private var artistContinuation: CheckedContinuation<[PathfinderArtist], Never>?

    func parkAlbums() async -> [PathfinderAlbum] {
        await withCheckedContinuation { albumContinuation = $0 }
    }

    func parkArtists() async -> [PathfinderArtist] {
        await withCheckedContinuation { artistContinuation = $0 }
    }

    func completeAlbums() {
        albumContinuation?.resume(returning: [])
        albumContinuation = nil
    }

    func completeArtists() {
        artistContinuation?.resume(returning: [])
        artistContinuation = nil
    }
}

@Suite("Workflow")
struct WorkflowTests {
    @Test
    @MainActor
    func queueBootstrapKeepsConnectOrderingDuringWebFallback() async {
        let web = HarnessWebQueue(.park)
        let service = QueueService(webQueue: web, metadata: TrackMetadataService(remote: HarnessRemote()))
        await service.reset(accountEpoch: 1)
        let refresh = Task {
            await service.refresh(fallbackEntries: [], currentTrackURI: "spotify:track:current", accountEpoch: 1)
        }
        #expect(await waitUntil { web.requestCount == 1 })
        let upcoming = QueueEntry(uri: "spotify:track:next", provider: "queue", occurrence: 0, uid: "next-occurrence")
        _ = await service.acceptConnect(
            [upcoming], accountEpoch: 1, sourceRevision: 1, contextURI: "spotify:track:current"
        )
        web.fail()
        let result = await refresh.value
        #expect(
            result?.entries == [upcoming],
            "startup's empty fallback cannot erase the Connect queue that arrived while Web was suspended")
        #expect(result?.tracks.map(\.uri) == [upcoming.uri], "the newly arrived upcoming tracks are hydrated")

        let later = await service.refresh(
            fallbackEntries: [], currentTrackURI: "spotify:track:current", accountEpoch: 1
        )
        #expect(later?.entries == [upcoming], "a stale caller projection cannot replace accepted Connect order")
    }

    @Test
    @MainActor
    func sidebarSelectionRoundTripsWithoutLeakingEntityIDs() async {
        let selection = SidebarSelection.playlist("spotify:playlist:sensitive-fixture")
        #expect(
            (SidebarSelection(rawValue: selection.rawValue)) == (selection),
            "selection round-trips through scene storage")
        #expect((selection.diagnosticLabel) == ("media:playlist"), "diagnostics retain the media kind")
        #expect(
            (!selection.diagnosticLabel.contains("sensitive-fixture")) == true,
            "diagnostics omit the Spotify entity id"
        )
    }

    @Test
    @MainActor
    func theCoordinatorReportsTypedOutcomesForLocalAndRemoteCommands() async {
        let local = HarnessEngine()
        let remote = HarnessRemote()
        let coordinator = PlaybackCoordinator(local: local, remote: remote)

        let localResult: Result<Void, PlaybackCommandFailure>
        do {
            localResult = try await coordinator.performLocalCommand(.pause)
        } catch {
            #expect((false) == true, "fake local command succeeds")
            return
        }
        try? await coordinator.performRemote(.shuffle(true), from: "source", to: "target")

        if case .success = localResult {
            #expect((true) == true, "fake local command succeeds")
        } else {
            #expect((false) == true, "fake local command succeeds")
        }
        #expect((local.operations.count) == (1), "one local command recorded")
        if case .pause? = local.operations.first {
            #expect((true) == true, "pause command reaches injected engine")
        } else {
            #expect((false) == true, "pause command reaches injected engine")
        }
        let endpoints = remote.endpoints
        #expect((endpoints.count) == (1), "one remote command recorded")
        #expect((endpoints.first) == (.shuffle), "shuffle reaches injected remote")
    }

    @Test
    @MainActor
    func aResetRejectsOldAccountWebQueueResults() async {
        let webQueue = HarnessWebQueue(.park)
        let remote = HarnessRemote()
        let service = QueueService(
            webQueue: webQueue,
            metadata: TrackMetadataService(remote: remote)
        )
        await service.reset(accountEpoch: 7)

        let refresh = Task {
            await service.refresh(
                fallbackEntries: [],
                currentTrackURI: "spotify:track:old",
                accountEpoch: 7
            )
        }
        while webQueue.requestCount == 0 { await Task.yield() }

        await service.reset(accountEpoch: 8)
        webQueue.complete(with: [workflowTrack("spotify:track:stale")])
        let staleResult = await refresh.value
        #expect((staleResult) == nil, "old-account web result is rejected after reset")

        let accepted = await service.acceptConnect(
            [QueueEntry(uri: "spotify:track:fresh", provider: "connect", occurrence: 0)],
            accountEpoch: 8,
            sourceRevision: 1,
            contextURI: "spotify:track:fresh"
        )
        #expect((accepted?.snapshot.accountEpoch) == (8), "new-account queue remains authoritative")
        #expect(
            (accepted?.snapshot.entries.first?.uri) == ("spotify:track:fresh"),
            "new-account queue retains fresh entry")

        let wrongAccount = await service.acceptConnect(
            [QueueEntry(uri: "spotify:track:wrong", provider: "connect", occurrence: 0)],
            accountEpoch: 7,
            sourceRevision: 2,
            contextURI: "spotify:track:wrong"
        )
        #expect((wrongAccount) == nil, "a stale account cannot read the replacement queue")
    }

    @Test
    @MainActor
    func aNewAccountProbesTheWebQueueCapabilityAgain() async {
        let webQueue = HarnessWebQueue(.rateLimited)
        let service = QueueService(
            webQueue: webQueue,
            metadata: TrackMetadataService(remote: HarnessRemote()),
            clock: HarnessClock(sleep: .immediate)
        )
        await service.reset(accountEpoch: 1)
        _ = await service.refresh(fallbackEntries: [], currentTrackURI: nil, accountEpoch: 1)
        _ = await service.refresh(fallbackEntries: [], currentTrackURI: nil, accountEpoch: 1)
        #expect(
            (webQueue.requestCount) == (1),
            "a 429 starts a session cooldown instead of retrying on every open")

        await service.reset(accountEpoch: 2)
        _ = await service.refresh(fallbackEntries: [], currentTrackURI: nil, accountEpoch: 2)
        #expect((webQueue.requestCount) == (2), "a new account gets a fresh Web queue capability probe")

        let old = workflowQueueSnapshot(
            revision: 1,
            contextURI: "spotify:track:old",
            entryURI: "spotify:track:old"
        )
        let replacement = workflowQueueSnapshot(
            revision: 2,
            contextURI: "spotify:track:new",
            entryURI: "spotify:track:new"
        )
        let merged = mergeQueueSnapshots(current: old, incoming: replacement)
        #expect(
            (merged.tracks.map(\.uri)) == (["spotify:track:new"]), "replacement queues discard unreachable metadata"
        )

        let connectUID = workflowQueueSnapshot(
            revision: 4,
            contextURI: "spotify:track:same",
            entryURI: "spotify:track:same",
            occurrence: 4,
            uid: "occ-4"
        )
        let webLabels = workflowQueueSnapshot(
            revision: 5,
            contextURI: "spotify:track:same",
            entryURI: "spotify:track:same",
            source: .webAPI,
            provider: "web-api"
        )
        let labeled = mergeQueueSnapshots(current: connectUID, incoming: webLabels)
        #expect(
            (labeled.entries.first?.uid ?? "") == ("occ-4"),
            "Web metadata merge keeps the Connect occurrence uid for the same URI index")
        let reorderedWeb = workflowQueueSnapshot(
            revision: 7,
            contextURI: "spotify:track:same",
            entryURI: "spotify:track:reordered",
            source: .webAPI,
            provider: "web-api"
        )
        let keptOrder = mergeQueueSnapshots(current: connectUID, incoming: reorderedWeb)
        #expect(
            (keptOrder.entries.map(\.uri)) == (["spotify:track:same"]),
            "same-context Web refresh keeps Connect occurrence order")
        #expect(
            (keptOrder.entries.first?.uid ?? "") == ("occ-4"),
            "same-context Web refresh keeps the Connect occurrence uid")
        #expect(
            (keptOrder.entries.first?.occurrence) == (4),
            "same-context Web refresh keeps the typed Connect occurrence")
        #expect((keptOrder.source) == (.connect), "same-context Web refresh stays Connect-owned")
        #expect(
            (keptOrder.revision) == (connectUID.revision),
            "same-context Web refresh does not copy the Web revision onto Connect order")
        #expect(
            (keptOrder.receivedAt) == (connectUID.receivedAt),
            "same-context Web refresh does not copy Web receivedAt onto Connect order")
        let changedURI = workflowQueueSnapshot(
            revision: 6,
            contextURI: "spotify:track:changed",
            entryURI: "spotify:track:changed",
            occurrence: 7,
            source: .webAPI,
            provider: "web-api"
        )
        #expect(
            (mergeQueueSnapshots(current: connectUID, incoming: changedURI).entries.first?.uid ?? "") == (""),
            "Web metadata merge does not invent a uid when the URI at that index changed")
        #expect(
            (mergeQueueSnapshots(current: connectUID, incoming: changedURI).entries.first?.uri ?? "")
                == ("spotify:track:changed"), "changed-URI Web merge uses the Web entry URI")
        #expect(
            (mergeQueueSnapshots(current: connectUID, incoming: changedURI).source) == (.webAPI),
            "changed-URI Web merge keeps Web provenance")
        #expect(
            (mergeQueueSnapshots(current: connectUID, incoming: changedURI).entries.first?.occurrence) == (7),
            "changed-context Web merge keeps its typed occurrence")

        let orderedService = QueueService(
            webQueue: HarnessWebQueue(
                .tracks([
                    workflowTrack("spotify:track:reordered"),
                    workflowTrack("spotify:track:same"),
                ])
            ),
            metadata: TrackMetadataService(remote: HarnessRemote()),
            clock: HarnessClock(sleep: .immediate)
        )
        await orderedService.reset(accountEpoch: 3)
        _ = await orderedService.acceptConnect(
            [QueueEntry(uri: "spotify:track:same", provider: "connect", occurrence: 0, uid: "occ-4")],
            accountEpoch: 3,
            sourceRevision: 1,
            contextURI: "spotify:track:same",
            protocolNext: [QueueProtocolTrack(uri: "spotify:track:same", uid: "occ-4", provider: "queue")]
        )
        let refreshed = await orderedService.refresh(
            fallbackEntries: [
                QueueEntry(uri: "spotify:track:same", provider: "connect", occurrence: 0, uid: "occ-4")
            ],
            currentTrackURI: "spotify:track:same",
            accountEpoch: 3
        )
        #expect(
            (refreshed?.entries.map(\.uri)) == (["spotify:track:same"]),
            "QueueService Web refresh keeps Connect occurrence URIs")
        #expect(
            (refreshed?.entries.first?.uid ?? "") == ("occ-4"),
            "QueueService Web refresh keeps Connect occurrence uids"
        )
        #expect((refreshed?.entries.first?.occurrence) == (0), "QueueService Web refresh keeps typed occurrence")
        #expect((refreshed?.source) == (.connect), "QueueService Web refresh stays Connect-owned")
        #expect((refreshed?.revision) == (1), "QueueService Web refresh keeps the Connect ordering revision")
        #expect(
            (await orderedService.mutationSnapshot()?.next.map(\.uid)) == (["occ-4"]),
            "Web refresh does not rewrite the Connect mutation snapshot")
        let laterConnect = await orderedService.acceptConnect(
            [
                QueueEntry(uri: "spotify:track:same", provider: "connect", occurrence: 0, uid: "occ-a"),
                QueueEntry(uri: "spotify:track:same", provider: "connect", occurrence: 1, uid: "occ-b"),
                QueueEntry(uri: "spotify:track:tail", provider: "connect", occurrence: 2, uid: "occ-c"),
            ],
            accountEpoch: 3,
            sourceRevision: 2,
            contextURI: "spotify:track:same",
            protocolNext: [
                QueueProtocolTrack(uri: "spotify:track:same", uid: "occ-a", provider: "queue"),
                QueueProtocolTrack(uri: "spotify:track:same", uid: "occ-b", provider: "queue"),
                QueueProtocolTrack(uri: "spotify:track:tail", uid: "occ-c", provider: "queue"),
            ]
        )
        #expect(
            (laterConnect?.snapshot.entries.map(\.uri))
                == (["spotify:track:same", "spotify:track:same", "spotify:track:tail"]),
            "a later Connect revision still replaces order after a Web refresh")
        #expect(
            (laterConnect?.snapshot.entries.map(\.uid)) == (["occ-a", "occ-b", "occ-c"]),
            "later Connect occurrences keep distinct uids")
        #expect(
            (laterConnect?.snapshot.entries.map(\.occurrence)) == ([0, 1, 2]),
            "later Connect occurrences keep typed positions")
        #expect(
            (await orderedService.mutationSnapshot()?.next.map(\.uid)) == (["occ-a", "occ-b", "occ-c"]),
            "a later Connect revision updates mutation metadata after a Web refresh")
    }

    @Test
    @MainActor
    func metadataUpdatesIncludeCachedEntriesWithBoundedConcurrency() async {
        let remote = HarnessRemote(metadata: .park)
        let metadata = TrackMetadataService(remote: remote)
        let service = QueueService(webQueue: HarnessWebQueue(), metadata: metadata)
        await service.reset(accountEpoch: 3)
        let entries = (0..<12).map {
            QueueEntry(uri: "spotify:track:\($0)", provider: "queue", occurrence: $0)
        }
        let cachedTracks = [workflowTrack("spotify:track:0"), workflowTrack("spotify:track:1")]
        let expectedRequestedURIs = Set(entries.map(\.uri)).subtracting(cachedTracks.map(\.uri))
        let updates = RuntimeCallbackRecorder<ProvenanceQueueSnapshot>()
        let refresh = Task {
            await service.refresh(
                fallbackEntries: entries,
                cachedTracks: cachedTracks,
                currentTrackURI: "spotify:track:current",
                accountEpoch: 3,
                onUpdate: { updates.append($0) }
            )
        }

        await expectEventually { remote.parkedMetadataRequestCount >= 8 }
        #expect(
            (updates.snapshot.first?.entries.count) == (12),
            "queue ordering is published before network hydration completes"
        )
        #expect((updates.snapshot.first?.tracks.count) == (2), "cached metadata is included in the first update")
        #expect((remote.parkedMetadataRequestCount) == (8), "all admitted metadata requests are held")
        #expect((remote.maximumActiveMetadataRequests) == (8), "metadata concurrency reaches its bound")

        let initiallyRequested = remote.requestedURIs
        if let first = initiallyRequested.first { remote.completeMetadata(for: first) }
        while remote.requestedURIs.count < 9 { await Task.yield() }
        #expect(
            await waitUntil { updates.snapshot.contains { $0.tracks.count == 3 } },
            "a completed lookup publishes in a bounded batch while other requests remain pending")

        var completed: Set<String> = Set(initiallyRequested.prefix(1))
        while completed.count < expectedRequestedURIs.count {
            for uri in remote.requestedURIs where completed.insert(uri).inserted {
                remote.completeMetadata(for: uri)
            }
            await Task.yield()
        }
        let final = await refresh.value
        #expect((final?.tracks.count) == (12), "all queue metadata eventually hydrates")
        #expect((final?.completeness) == (.complete), "hydration completion marks the queue complete")
        #expect((final?.entries.map(\.id)) == (entries.map(\.id)), "queue ordering never changes during enrichment")
    }

    @Test
    @MainActor
    func concurrentMetadataConsumersShareOneRemoteLookup() async {
        let remote = HarnessRemote(metadata: .park)
        let metadata = TrackMetadataService(remote: remote)
        let uri = "spotify:track:shared"
        let first = Task { try? await metadata.metadata(for: uri) }
        let second = Task { try? await metadata.metadata(for: uri) }
        while remote.requestedURIs.isEmpty { await Task.yield() }
        #expect((remote.requestedURIs.count) == (1), "concurrent consumers issue one remote lookup")
        remote.completeMetadata(for: uri)
        let values = await [first.value, second.value]
        #expect((values.compactMap { $0 }.count) == (2), "both consumers receive the shared result")
        _ = try? await metadata.metadata(for: uri)
        #expect((remote.requestedURIs.count) == (1), "the account-scoped cache avoids a second lookup")
    }

    @Test
    @MainActor
    func catalogMetadataRetainsQueueTracksAcrossSectionReplacement() async {
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let metadata = CatalogMetadataRepository(
            attributesProvider: HarnessTrackAttributes(),
            session: session
        )
        let queued = workflowTrack("spotify:track:queued")
        let unrelated = workflowTrack("spotify:track:unrelated")

        metadata.retainTracks(from: .queue, for: [queued.uri])
        metadata.replaceTracks([queued], from: .playlist)
        metadata.replaceTracks([unrelated], from: .playlist)
        metadata.replaceTracks([], from: .queue)
        metadata.replaceTracks([], from: .playlist)

        #expect(
            (metadata.knownTrack(for: queued.uri)?.uri) == (queued.uri),
            "visited playlist metadata survives for the active queue")
        #expect(
            (metadata.knownTrack(for: unrelated.uri)) == nil,
            "unrelated playlist metadata is not retained with the queue")

        metadata.retainTracks(from: .queue, for: [])
        metadata.replaceTracks([], from: .queue)
        #expect(
            (metadata.knownTrack(for: queued.uri)) == nil, "queue metadata is released when its ordering clears")
    }

    @Test
    @MainActor
    func homeLibraryLoadsCoalesceDuplicateSectionRequests() async {
        let provider = HarnessCatalog()
        let gate = LibraryParkGate()
        provider.onLibraryAlbums = { [gate] in await gate.parkAlbums() }
        provider.onLibraryArtists = { [gate] in await gate.parkArtists() }
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let metadata = CatalogMetadataRepository(
            attributesProvider: HarnessTrackAttributes(),
            session: session
        )
        let store = HomeLibraryStore(provider: provider, metadata: metadata, session: session)

        let albums = Task { await store.loadAlbums() }
        while provider.libraryAlbumRequestCount == 0 { await Task.yield() }
        let albumFollower = Task { await store.loadAlbums() }
        let artists = Task { await store.loadArtists() }
        while provider.libraryArtistRequestCount == 0 { await Task.yield() }

        #expect((provider.libraryAlbumRequestCount) == (1), "duplicate requests for one section coalesce")

        await gate.completeAlbums()
        await gate.completeArtists()
        await albums.value
        await albumFollower.value
        await artists.value

        #expect((store.loadedSections.contains(.albums)) == true, "overlapping album load remains current")
        #expect((store.loadedSections.contains(.artists)) == true, "overlapping artist load remains current")
        #expect((!store.isLoading) == true, "both independent loading indicators finish")
    }

    @Test
    @MainActor
    func emptyAlbumAndArtistLoadsStillCompleteTheirSections() async {
        let provider = HarnessCatalog()
        provider.onAlbum = { id in
            PathfinderAlbumUnion(
                uri: "spotify:album:\(id)",
                name: "Empty Album",
                type: "album",
                date: nil,
                coverArt: nil,
                artists: nil,
                tracksV2: PathfinderAlbumUnion.TrackList(items: [], totalCount: 0)
            )
        }
        provider.onArtist = { id in
            PathfinderArtistUnion(
                uri: "spotify:artist:\(id)",
                id: id,
                profile: PathfinderArtistUnion.Profile(name: "Empty Artist"),
                visuals: nil,
                discography: nil
            )
        }
        provider.onArtistDiscography = { id in
            PathfinderArtistUnion(
                uri: "spotify:artist:\(id)",
                id: id,
                profile: nil,
                visuals: nil,
                discography: nil
            )
        }
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let metadata = CatalogMetadataRepository(
            attributesProvider: HarnessTrackAttributes(),
            session: session
        )
        let albumStore = AlbumDetailStore(provider: provider, metadata: metadata, session: session)
        let artistStore = ArtistDetailStore(provider: provider, session: session)
        let album = CatalogItem(
            id: "empty-album",
            uri: "spotify:album:empty-album",
            title: "Empty Album",
            subtitle: "",
            artworkURL: nil,
            kind: .album
        )
        let artist = CatalogItem(
            id: "empty-artist",
            uri: "spotify:artist:empty-artist",
            title: "Empty Artist",
            subtitle: "",
            artworkURL: nil,
            kind: .artist
        )

        await albumStore.load(album)
        await albumStore.load(album)
        await artistStore.load(artist)
        await artistStore.load(artist)

        #expect((provider.albumRequestCount) == (1), "an empty album is still a completed load")
        #expect((provider.artistRequestCount) == (1), "an empty artist overview is still a completed load")
        #expect((provider.discographyRequestCount) == (1), "an empty discography is still a completed load")

        session.update(accountEpoch: 1, isAvailable: false)
        session.update(accountEpoch: 1, isAvailable: true)
        await albumStore.load(album)
        await artistStore.load(artist)
        #expect((provider.albumRequestCount) == (2), "a new catalog session reloads the album")
        #expect((provider.artistRequestCount) == (2), "a new catalog session reloads the artist")
    }

    @Test
    @MainActor
    func initializationSubscribesToNothingBeforeRestore() async {
        let engine = HarnessEngine(
            events: .live, resumePosition: 10, resumeContextURI: "spotify:playlist:ctx",
            resumeTrackURI: "spotify:track:one"
        )
        let account = HarnessAccount(hasGrant: true, authorization: .succeed, revocations: .live)
        let lifecycle = HarnessLifecycleEvents(.live)
        let environment = HarnessEnvironment.make(
            engine: engine,
            account: account,
            lifecycle: lifecycle,
            clock: HarnessClock(sleep: .immediate)
        )
        let speculative = HarnessEnvironment.makePlaybackStore(environment)
        _ = speculative
        await Task.yield()
        #expect((engine.count(.events)) == (0), "initialization does not subscribe to engine events")
        #expect((account.subscriptionCount) == (0), "initialization does not subscribe to grant revocations")
        #expect((lifecycle.subscriptionCount) == (0), "initialization does not subscribe to lifecycle events")

        let player = HarnessEnvironment.makePlaybackStore(environment)
        await player.restore()
        #expect(
            (await waitUntil {
                engine.count(.events) != 0 && account.subscriptionCount != 0
                    && lifecycle.subscriptionCount != 0
            }) == true, "restore installs every process subscription")
        #expect(player.phase == .connecting, "restoration awaits engine readiness")
        engine.emit(
            workflowConnectionEnvelope(
                sequence: 1, sessionGeneration: player.engineGeneration, spircReady: true, resumePending: false
            )
        )
        #expect(await waitUntil { player.phase == .ready }, "engine observation makes the restored store ready")
        #expect((engine.count(.initialize)) == (1), "engine initializes once")
        #expect((engine.count(.events)) == (1), "restore starts one engine-event subscription")
        #expect((account.subscriptionCount) == (1), "restore starts one grant-revocation subscription")
        #expect((lifecycle.subscriptionCount) == (1), "restore starts one lifecycle subscription")

        await player.restore()
        #expect(
            (engine.count(.events)) == (1),
            "repeated restore does not replace the engine-event subscription")
        #expect(
            (account.subscriptionCount) == (1),
            "repeated restore does not replace the grant-revocation subscription")
        #expect(
            (lifecycle.subscriptionCount) == (1), "repeated restore does not replace the lifecycle subscription")

        lifecycle.emit(.willSleep)
        #expect(await waitUntil { engine.count(.disconnect) == 1 }, "sleep reaches the engine")
        lifecycle.emit(.didWake)
        #expect(await waitUntil { engine.count(.forceReconnect) == 1 }, "wake reaches the engine")
        #expect((engine.count(.disconnect)) == (1), "sleep disconnects once")
        #expect((engine.count(.forceReconnect)) == (1), "wake reconnects once")

        let oldEpoch = player.state.accountEpoch
        await player.logout()
        #expect((account.clearCount) == (1), "logout clears the grant")
        #expect((player.state.accountEpoch) == (oldEpoch + 1), "logout advances account identity")
        #expect((engine.count(.shutdown)) == (1), "logout shuts the engine down once")
        #expect((player.trackURI) == (""), "logout clears presentation")

        engine.emit(
            RustPlaybackEventEnvelope(
                sequence: 99,
                receivedAt: Date(),
                event: .playback(
                    RustPlaybackState(
                        revision: 99,
                        sessionGeneration: 0,
                        isPlaying: true,
                        isPaused: false,
                        trackURI: "spotify:track:stale",
                        positionMS: 1_000,
                        durationMS: 10_000,
                        timestampMS: 0,
                        shuffle: false,
                        repeatTrack: false,
                        repeatContext: false
                    ))
            ))
        await Task.yield()
        #expect((player.trackURI) == (""), "old engine callback cannot repopulate signed-out state")

        await player.shutdownForTermination()
        await player.shutdownForTermination()
        #expect(
            (await waitUntil {
                engine.activeEventSubscriptionCount == 0 && account.activeSubscriptionCount == 0
                    && lifecycle.activeSubscriptionCount == 0
            }) == true, "termination settles every process subscription")
        #expect((engine.count(.shutdown)) == (2), "termination shutdown is idempotent")
        #expect(
            (engine.activeEventSubscriptionCount) == (0), "termination cancels the engine-event subscription")
        #expect((account.activeSubscriptionCount) == (0), "termination cancels the grant-revocation subscription")
        #expect((lifecycle.activeSubscriptionCount) == (0), "termination cancels the lifecycle subscription")
    }

    @Test
    @MainActor
    func rehydrationNamesTheEngineSessionItBelongsTo() async {
        let engine = HarnessEngine(
            events: .live, resumePosition: 10, resumeContextURI: "spotify:playlist:ctx",
            resumeTrackURI: "spotify:track:one"
        )
        let account = HarnessAccount(hasGrant: true, authorization: .succeed, revocations: .live)
        let lifecycle = HarnessLifecycleEvents(.live)
        let environment = HarnessEnvironment.make(
            engine: engine,
            account: account,
            lifecycle: lifecycle,
            clock: HarnessClock(sleep: .immediate)
        )
        let player = HarnessEnvironment.makePlaybackStore(environment)
        await player.restore()
        #expect(
            (await waitUntil { engine.count(.events) != 0 }) == true,
            "restore subscribes to engine events"
        )
        let expectedPlan = ResumeLoadPlan(
            positionMS: 10,
            contextURI: "spotify:playlist:ctx",
            trackURI: "spotify:track:one"
        )

        engine.emit(
            workflowConnectionEnvelope(sequence: 1, sessionGeneration: 1, spircReady: false, resumePending: true))
        #expect(
            (await waitUntil { engine.rehydrations.count == 1 }) == true,
            "a pending, not-ready connection snapshot triggers one rehydration")
        #expect(
            (engine.rehydrations.first) == (expectedPlan),
            "rehydration captures the sticky engine identity, not presentation")
        #expect((engine.rehydratedGenerations) == ([1]), "rehydration names the engine session it belongs to")

        await player.effects.settlement(of: .reconnectRehydration)?.wait()
        engine.emit(
            workflowConnectionEnvelope(sequence: 2, sessionGeneration: 1, spircReady: false, resumePending: true))
        engine.emit(
            workflowConnectionEnvelope(sequence: 3, sessionGeneration: 1, spircReady: true, resumePending: false))
        #expect(
            (await waitUntil { player.state.sourceRevisions[.engineConnection] == 3 }) == true,
            "the ready snapshot is accepted after the window")
        #expect(
            (engine.rehydrations.count) == (1), "a republished window and the ready snapshot do not rehydrate again"
        )

        engine.emit(
            workflowConnectionEnvelope(sequence: 4, sessionGeneration: 2, spircReady: false, resumePending: true))
        #expect(
            (await waitUntil { engine.rehydrations.count == 2 }) == true,
            "a later engine session rehydrates once more")

        await player.effects.settlement(of: .reconnectRehydration)?.wait()
        engine.emit(
            workflowConnectionEnvelope(sequence: 5, sessionGeneration: 3, spircReady: true, resumePending: true))
        #expect(
            (await waitUntil { player.state.sourceRevisions[.engineConnection] == 5 }) == true,
            "the contradictory snapshot is accepted")
        #expect((engine.rehydrations.count) == (2), "a ready snapshot never rehydrates even if the flag is set")

        await player.shutdownForTermination()
    }

    @Test
    @MainActor
    func aRehydrationWhoseWindowClosedWhileQueuedIssuesNoLoad() async {
        let engine = HarnessEngine(
            events: .live, resumePosition: 10, resumeContextURI: "spotify:playlist:ctx",
            resumeTrackURI: "spotify:track:one"
        )
        let account = HarnessAccount(hasGrant: true, authorization: .succeed, revocations: .live)
        let lifecycle = HarnessLifecycleEvents(.live)
        let environment = HarnessEnvironment.make(
            engine: engine,
            account: account,
            lifecycle: lifecycle,
            clock: HarnessClock(sleep: .immediate)
        )
        let player = HarnessEnvironment.makePlaybackStore(environment)
        await player.restore()
        #expect(
            (await waitUntil { engine.count(.events) != 0 }) == true,
            "restore subscribes to engine events"
        )
        let coordinator = player.coordinator
        let gate = HarnessEngineGate(result: .ok)

        // Same generation: the window closes (ready snapshot) while the coordinator is busy.
        engine.onExecute = { [gate] _ in gate.enter() }
        let busy = Task { await coordinator.performLocal(.pause) }
        #expect(
            (await waitUntil { gate.hasStarted && !busy.isCancelled }) == true,
            "the coordinator is occupied by an earlier local command")
        player.receive(
            workflowConnectionEnvelope(sequence: 1, sessionGeneration: 1, spircReady: false, resumePending: true))
        #expect((player.rehydratedSessionGeneration == 1) == true, "the rehydration is claimed for this generation")
        player.receive(
            workflowConnectionEnvelope(sequence: 2, sessionGeneration: 1, spircReady: true, resumePending: false))
        engine.onExecute = nil
        gate.finish(with: .ok)
        _ = await busy.value
        await player.effects.settlement(of: .reconnectRehydration)?.wait()
        #expect((engine.rehydrations.count) == (0), "a rehydration whose window closed while queued issues no load")
        #expect((engine.operations.count) == (1), "the earlier command still executed")

        // New generation: the engine session changes while the coordinator is busy.
        engine.onExecute = { [gate] _ in gate.enter() }
        let busyAgain = Task { await coordinator.performLocal(.pause) }
        #expect(
            (await waitUntil { gate.enteredCount == 2 }) == true,
            "the coordinator is occupied before the replacement generation arrives")
        player.receive(
            workflowConnectionEnvelope(sequence: 3, sessionGeneration: 2, spircReady: false, resumePending: true))
        #expect(
            (player.rehydratedSessionGeneration == 2) == true,
            "the rehydration is claimed for the second generation")
        player.receive(
            workflowConnectionEnvelope(sequence: 4, sessionGeneration: 3, spircReady: false, resumePending: true))
        engine.onExecute = nil
        gate.finish(with: .ok)
        _ = await busyAgain.value
        #expect(
            (await waitUntil { engine.rehydrations.count == 1 }) == true,
            "the newer generation's own rehydration runs")
        await player.effects.settlement(of: .reconnectRehydration)?.wait()
        #expect((engine.rehydrations.count) == (1), "the superseded generation's rehydration never loads")
        #expect((engine.operations.count) == (3), "only the two pauses and one rehydration reached the engine")

        await player.shutdownForTermination()
    }

    @Test
    @MainActor
    func terminationDuringBootstrapPreventsEngineInitialization() async {
        let engine = HarnessEngine(
            events: .live, resumePosition: 10, resumeContextURI: "spotify:playlist:ctx",
            resumeTrackURI: "spotify:track:one"
        )
        let account = HarnessAccount(hasGrant: true, authorization: .succeed, revocations: .live)
        let lifecycle = HarnessLifecycleEvents(.live)
        let hook = QueueServiceTestHook()
        await hook.parkNextReset()
        let environment = HarnessEnvironment.make(
            engine: engine,
            account: account,
            lifecycle: lifecycle,
            clock: HarnessClock(sleep: .immediate),
            queueServiceHook: hook
        )
        let player = HarnessEnvironment.makePlaybackStore(environment)

        let restore = Task { await player.restore() }
        #expect(
            (await waitUntil { await hook.resetIsParked() }) == true, "queue bootstrap parks before engine restore")
        await player.shutdownForTermination()
        await restore.value

        #expect((engine.count(.initialize)) == (0), "termination during bootstrap prevents engine initialization")
        #expect((engine.count(.shutdown)) == (1), "termination during bootstrap shuts down once")
        #expect((player.phase) == (.signedOut), "termination during bootstrap leaves the store signed out")
        #expect(
            (engine.activeEventSubscriptionCount) == (0),
            "cancelled bootstrap leaves no active engine subscription")
        #expect(
            (account.activeSubscriptionCount) == (0), "cancelled bootstrap leaves no active revocation subscription"
        )
        #expect(
            (lifecycle.activeSubscriptionCount) == (0),
            "cancelled bootstrap leaves no active lifecycle subscription")
    }

    @Test
    @MainActor
    func aLatePreferenceReadCannotRestoreStaleState() async {
        let engine = HarnessEngine(
            events: .live, resumePosition: 10, resumeContextURI: "spotify:playlist:ctx",
            resumeTrackURI: "spotify:track:one"
        )
        let account = HarnessAccount(hasGrant: true, authorization: .succeed, revocations: .live)
        let lifecycle = HarnessLifecycleEvents(.live)
        let preferences = HarnessPreferences(
            lastRemoteDeviceID: "spotify:device:stale",
            shuffleHistory: ["spotify:track:stale": 1],
            parkShuffleReads: true
        )
        let environment = HarnessEnvironment.make(
            engine: engine,
            account: account,
            preferences: preferences,
            lifecycle: lifecycle,
            clock: HarnessClock(sleep: .immediate)
        )
        let player = HarnessEnvironment.makePlaybackStore(environment)

        let restore = Task { await player.restore() }
        #expect(
            (await waitUntil { preferences.shuffleIsParked() && engine.count(.initialize) == 1 }) == true,
            "preference read parks while account restoration proceeds")
        await player.shutdownForTermination()
        preferences.resumeShuffle()
        await restore.value

        #expect((player.state.options.shuffle) == (false), "late preference read cannot restore shuffle")
        #expect((player.lastRemoteDeviceID) == nil, "late preference read cannot restore a remote device")
        #expect((player.shuffleHistoryCache) == ([:]), "late preference read cannot restore shuffle history")
        #expect((engine.count(.shutdown)) == (1), "termination after account restore shuts down once")
    }
}

private func workflowTrack(_ uri: String) -> CatalogTrack {
    CatalogTrack(
        id: uri,
        uri: uri,
        title: "Track",
        artist: "Artist",
        album: "Album",
        duration: 180,
        artworkURL: nil,
        addedAt: nil
    )
}

private func workflowConnectionEnvelope(
    sequence: UInt64,
    sessionGeneration: UInt64,
    spircReady: Bool,
    resumePending: Bool
) -> RustPlaybackEventEnvelope {
    RustPlaybackEventEnvelope(
        sequence: sequence,
        receivedAt: Date(),
        event: .connection(
            RustConnectionState(
                revision: sequence,
                sessionGeneration: sessionGeneration,
                sessionConnected: true,
                spircReady: spircReady,
                isActiveDevice: true,
                resumePending: resumePending,
                lastError: nil,
                deviceID: "local"
            ))
    )
}

private func workflowQueueSnapshot(
    revision: UInt64,
    contextURI: String,
    entryURI: String,
    occurrence: Int = 0,
    source: PlaybackQueueSource = .connect,
    uid: String = "",
    provider: String = "connect"
) -> ProvenanceQueueSnapshot {
    ProvenanceQueueSnapshot(
        accountEpoch: 1,
        revision: revision,
        source: source,
        completeness: .complete,
        receivedAt: Date(timeIntervalSince1970: TimeInterval(revision)),
        contextURI: contextURI,
        entries: [QueueEntry(uri: entryURI, provider: provider, occurrence: occurrence, uid: uid)],
        tracks: [workflowTrack(entryURI)]
    )
}
