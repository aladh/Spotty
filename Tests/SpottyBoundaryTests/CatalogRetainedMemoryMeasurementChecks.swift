@testable import SpottyRuntimeTestSupport
import SpottyTestSupport
import Darwin
import Foundation
import Observation
import SpottyDomain
import SpottyRuntimeContracts
import Testing
@testable import SpottyCore

/// One synthetic workload per native PID. Provider rows exist only inside calls;
/// peak RSS is retained as a separate high-water observation, never a release metric.
@MainActor
struct CatalogRetainedMemoryMeasurementTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPOTTY_CATALOG_MEMORY_REPORT"] != nil))
    func measureIsolatedCatalogRetention() async throws {
        #if DEBUG && SPOTTY_BROWSING_OPTIMIZED
            let configuration = try Configuration()
            let recorder = Recorder(configuration)
            let witness = LifetimeWitness()
            let result: Result<[String: Any], any Error>
            do {
                try await recorder.admitNativeHost()
                try await recorder.checkpoint("pre-fixture", state: [:])
                result = .success(try await runFixture(configuration, recorder: recorder, witness: witness))
            } catch {
                result = .failure(error)
            }
            // This owned cleanup task does not inherit caller cancellation. The helper's
            // strong locals have left scope before its weak lifetime witnesses are checked.
            let ownerRelease = Task { @MainActor in
                try await requireEventually(description: "Catalog measurement fixture owners release") {
                    witness.store == nil && witness.metadata == nil && witness.provider == nil && witness.queries == nil
                }
            }
            var ownersReleased = false
            do {
                try await ownerRelease.value
                ownersReleased = true
            } catch {
                recorder.recordCleanupFailure("owner-release", error: error)
                if case .success = result {
                    recorder.fail(error, fixtureOwnersReleased: false)
                    throw error
                }
            }
            switch result {
            case let .failure(error):
                recorder.fail(error, fixtureOwnersReleased: ownersReleased)
                throw error
            case let .success(workload):
                do {
                    try await recorder.checkpoint("owner-release", state: ["fixtureOwnersReleased": true])
                    try recorder.finish(workload: workload)
                } catch {
                    recorder.fail(error, fixtureOwnersReleased: true)
                    throw error
                }
            }
        #else
            throw MeasurementFailure(
                "This opt-in probe requires the verified optimized Debug native/non-WMO test profile; its controller must admit actual compiler metadata"
            )
        #endif
    }

    private struct MeasurementFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private struct Configuration: Sendable {
        let nonce: String
        let workload: String
        let rows: Int
        let report: URL
        let gateDirectory: URL?
        let attribution: Bool

        var routes: Int { workload == "switch-ab" || rows == 10_000 ? 2 : 1 }
        var oversizedSwitch: Bool { workload == "switch-ab" && rows == 40_000 }
        var iterations: Int { oversizedSwitch ? 10 : 100 }

        init() throws {
            let environment = ProcessInfo.processInfo.environment
            guard let nonce = environment["SPOTTY_CATALOG_MEMORY_NONCE"], UUID(uuidString: nonce) != nil,
                let workload = environment["SPOTTY_CATALOG_MEMORY_WORKLOAD"],
                ["same-selection", "switch-ab"].contains(workload),
                let encodedRows = environment["SPOTTY_CATALOG_MEMORY_ROWS"], let rows = Int(encodedRows),
                [500, 10_000, 40_000].contains(rows),
                let path = environment["SPOTTY_CATALOG_MEMORY_REPORT"], !path.isEmpty
            else {
                throw MeasurementFailure(
                    "Expected a nonce, one workload, one supported row count, and a new report path")
            }
            let attributionValue = environment["SPOTTY_CATALOG_MEMORY_ATTRIBUTION"] ?? "0"
            guard ["0", "1"].contains(attributionValue) else { throw MeasurementFailure("Invalid attribution mode") }
            self.nonce = nonce
            self.workload = workload
            self.rows = rows
            report = URL(fileURLWithPath: path)
            attribution = attributionValue == "1"
            if let directory = environment["SPOTTY_CATALOG_MEMORY_GATE_DIR"] {
                guard attribution, !directory.isEmpty else {
                    throw MeasurementFailure("Snapshot gates require attribution mode")
                }
                let url = URL(fileURLWithPath: directory)
                guard FileManager.default.fileExists(atPath: url.path),
                    try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty
                else { throw MeasurementFailure("Snapshot gate directory must already exist and be empty") }
                gateDirectory = url
            } else {
                guard !attribution else {
                    throw MeasurementFailure("Attribution mode requires exact-PID snapshot gates")
                }
                gateDirectory = nil
            }
            guard !FileManager.default.fileExists(atPath: report.path) else {
                throw MeasurementFailure("Measurement report path already exists")
            }
        }
    }

    @MainActor
    private final class LifetimeWitness {
        weak var store: PlaylistStore?
        weak var metadata: CatalogMetadataRepository?
        weak var provider: HarnessCatalog?
        weak var queries: HarnessCatalogQueries?
    }

    private struct RouteIdentity: Equatable, Sendable {
        let version: UUID
        let firstID: String
        let lastID: String
        let firstUID: String?
        let lastUID: String?

        @MainActor
        init(_ store: PlaylistStore) {
            version = store.trackCollection.version
            firstID = store.tracks.first?.id ?? ""
            lastID = store.tracks.last?.id ?? ""
            firstUID = store.tracks.first?.occurrenceUID
            lastUID = store.tracks.last?.occurrenceUID
        }
    }

    private func runFixture(
        _ configuration: Configuration, recorder: Recorder, witness: LifetimeWitness
    ) async throws -> [String: Any] {
        let queries = HarnessCatalogQueries()
        let provider = HarnessCatalog()
        provider.entityQueries = queries
        // Capture scalar configuration only. Retaining preconstructed response arrays here
        // would prevent route eviction from releasing the measured membership graph.
        let rows = configuration.rows
        provider.onPlaylist = { id in
            CatalogPlaylistSnapshot(
                description: id, ownerURI: nil,
                tracks: Self.makeRows(id: id, count: id == "memory-small" ? 1 : rows))
        }
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let metadata = CatalogMetadataRepository(session: session)
        let store = PlaylistStore(provider: provider, metadata: metadata, session: session)
        witness.queries = queries
        witness.provider = provider
        witness.metadata = metadata
        witness.store = store
        let result: Result<[String: Any], any Error>
        do {
            result = .success(
                try await runWorkload(
                    configuration, recorder: recorder, store: store, metadata: metadata,
                    provider: provider, queries: queries, session: session))
        } catch {
            result = .failure(error)
        }
        // Reset queues asynchronous unsubscribe through the provider. Keep that bridge
        // connected through bounded drain, including throws and caller cancellation.
        let cleanup = Task { @MainActor in
            try await drainFixture(store, metadata: metadata, queries: queries)
            provider.onPlaylist = nil
            provider.entityQueries = nil
        }
        do {
            try await cleanup.value
        } catch {
            recorder.recordCleanupFailure("query-drain", error: error)
            if case .success = result { throw error }
        }
        return try result.get()
    }

    private func drainFixture(
        _ store: PlaylistStore, metadata: CatalogMetadataRepository, queries: HarnessCatalogQueries
    ) async throws {
        store.reset()
        metadata.reset()
        await queries.finishStreams()
        try await requireEventually(description: "Catalog measurement queries drain") {
            await queries.activeQueryCount == 0
        }
    }

    private func runWorkload(
        _ configuration: Configuration, recorder: Recorder, store: PlaylistStore, metadata: CatalogMetadataRepository,
        provider: HarnessCatalog, queries: HarnessCatalogQueries, session: CatalogSessionAvailability
    ) async throws -> [String: Any] {
        let rows = configuration.rows
        let a = Self.item("memory-a")
        let b = Self.item("memory-b")
        var identities: [String: RouteIdentity] = [:]
        await store.load(a)
        identities[a.uri] = RouteIdentity(store)
        if configuration.routes == 2 {
            await store.load(b)
            identities[b.uri] = RouteIdentity(store)
        }
        let last = configuration.routes == 2 ? b : a
        let requested = min(
            (rows - 1) * (rows <= 20_000 ? configuration.routes : 1), CatalogEntityQueryLimits.maximumRequestedURIs)
        try await requireEventually {
            await queries.memoryQueryIsSettled(
                expectedCount: requested, selectedTrackPrefix: rows > 20_000 ? "spotify:track:\(last.id)-" : nil)
        }
        try #require(store.tracks.count == rows)
        try #require(provider.playlistRequestCount == configuration.routes)
        if rows <= 20_000 {
            if configuration.routes == 2 {
                try verifyAtomicSwitch(store, metadata: metadata, from: last, to: a)
                try #require(RouteIdentity(store) == identities[a.uri])
            }
            store.prepare(last)
            try #require(RouteIdentity(store) == identities[last.uri])
        }
        try await recorder.checkpoint("post-load", state: await state(store, provider: provider, queries: queries))
        try #require(metadata.browsingMetadata.tracks.count == rows - 1)
        try await recorder.checkpoint(
            "post-load-export", state: ["exportedEntities": rows - 1, "exportSnapshotHeld": false])
        let initialRequests = provider.playlistRequestCount
        let initialSubscriptions = await queries.subscriptionCount
        var preparationCPU = 0.0
        var preparationWall = 0.0
        var reloadCPU = 0.0
        var reloadWall = 0.0
        if configuration.oversizedSwitch {
            // Oversized A/B visits have no retained restoration. Time only prepare in
            // its own window; explicitly report each construction/load/settlement cost.
            for iteration in 0..<configuration.iterations {
                let selected = iteration.isMultiple(of: 2) ? a : b
                let before = try cpuSeconds()
                let started = ContinuousClock.now
                store.prepare(selected)
                preparationWall += seconds(started.duration(to: .now))
                preparationCPU += try cpuSeconds() - before
                try #require(store.tracks.isEmpty)
                let beforeReload = try cpuSeconds()
                let reloadStarted = ContinuousClock.now
                await store.load(selected)
                try await requireEventually {
                    await queries.memoryQueryIsSettled(
                        expectedCount: requested, selectedTrackPrefix: "spotify:track:\(selected.id)-")
                }
                reloadWall += seconds(reloadStarted.duration(to: .now))
                reloadCPU += try cpuSeconds() - beforeReload
                try #require(store.tracks.count == rows)
            }
            try #require(provider.playlistRequestCount == initialRequests + configuration.iterations)
        } else {
            for _ in 0..<5 { store.prepare(last) }
            let before = try cpuSeconds()
            let started = ContinuousClock.now
            for iteration in 0..<configuration.iterations {
                let selected = configuration.workload == "same-selection" ? last : (iteration.isMultiple(of: 2) ? a : b)
                store.prepare(selected)
            }
            preparationWall = seconds(started.duration(to: .now))
            preparationCPU = try cpuSeconds() - before
            try #require(RouteIdentity(store) == identities[last.uri])
            try #require(provider.playlistRequestCount == initialRequests)
            try #require(await queries.subscriptionCount == initialSubscriptions)
        }
        try #require(store.item?.uri == last.uri && store.tracks.count == rows)
        try await recorder.checkpoint("post-switch", state: await state(store, provider: provider, queries: queries))
        try #require(metadata.browsingMetadata.tracks.count == rows - 1)
        try await recorder.checkpoint(
            "post-switch-export", state: ["exportedEntities": rows - 1, "exportSnapshotHeld": false])

        // Exercise the shipping twenty-route limit at 500 rows, and its twenty-thousand
        // row limit with two ten-thousand routes. No custom low retention budget is used.
        if rows == 500 {
            for index in configuration.routes..<20 { await store.load(Self.item("memory-fill-\(index)")) }
        }
        await store.load(Self.item("memory-small"))
        store.prepare(a)
        try #require(store.tracks.isEmpty, "LRU route A is evicted, or was too large to retain")
        if rows == 10_000 {
            store.prepare(b)
            try #require(store.tracks.count == rows && RouteIdentity(store) == identities[b.uri])
        } else if rows == 40_000 {
            store.prepare(b)
            try #require(store.tracks.isEmpty, "Forty-thousand rows never become retained content")
        }
        // Consume deletion deltas without retaining the export value in the fixture.
        _ = metadata.browsingMetadata.tracks.count
        let remainingRequested = rows == 500 ? 19 * (rows - 1) + 1 : (rows == 10_000 ? rows : 1)
        try await requireEventually { await queries.activeRequestedURIs.count == remainingRequested }
        try await recorder.checkpoint("post-eviction", state: await state(store, provider: provider, queries: queries))
        if rows == 500 {
            for index in configuration.routes..<20 {
                store.invalidateRetainedPlaylist(Self.item("memory-fill-\(index)").uri)
            }
        }
        store.invalidateRetainedPlaylist(a.uri)
        store.invalidateRetainedPlaylist(b.uri)
        store.invalidateRetainedPlaylist(Self.item("memory-small").uri)
        store.prepare(Self.item("memory-empty"))
        try #require(store.tracks.isEmpty && metadata.browsingMetadata.tracks.isEmpty)
        try await requireEventually { await queries.activeQueryCount == 0 }
        try await recorder.checkpoint(
            "post-invalidation", state: await state(store, provider: provider, queries: queries))
        // Reconstruct the configured routes after explicit invalidation. This separate
        // setup cost cannot enter the primary preparation or oversized-reload windows.
        let retirementRequests = provider.playlistRequestCount
        let beforeRetirementReload = try cpuSeconds()
        let retirementReloadStarted = ContinuousClock.now
        await store.load(a)
        let retirementA = RouteIdentity(store)
        try #require(store.tracks.count == rows && retirementA.version != identities[a.uri]?.version)
        try #require(
            retirementA.firstID == identities[a.uri]?.firstID && retirementA.lastID == identities[a.uri]?.lastID)
        try #require(
            retirementA.firstUID == identities[a.uri]?.firstUID && retirementA.lastUID == identities[a.uri]?.lastUID)
        if rows <= 20_000 {
            store.prepare(Self.item("memory-empty"))
            store.prepare(a)
            try #require(RouteIdentity(store) == retirementA)
        }
        if configuration.routes == 2 {
            await store.load(b)
            let retirementB = RouteIdentity(store)
            try #require(store.tracks.count == rows && retirementB.version != identities[b.uri]?.version)
            try #require(
                retirementB.firstID == identities[b.uri]?.firstID && retirementB.lastID == identities[b.uri]?.lastID)
            try #require(
                retirementB.firstUID == identities[b.uri]?.firstUID && retirementB.lastUID == identities[b.uri]?.lastUID
            )
            if rows <= 20_000 {
                store.prepare(a)
                try #require(RouteIdentity(store) == retirementA)
                store.prepare(b)
                try #require(RouteIdentity(store) == retirementB)
            }
        }
        try await requireEventually {
            await queries.memoryQueryIsSettled(
                expectedCount: requested, selectedTrackPrefix: rows > 20_000 ? "spotify:track:\(last.id)-" : nil)
        }
        let retirementReloadCPU = try cpuSeconds() - beforeRetirementReload
        let retirementReloadWall = seconds(retirementReloadStarted.duration(to: .now))
        try #require(provider.playlistRequestCount == retirementRequests + configuration.routes)
        try #require(store.item?.uri == last.uri && store.tracks.count == rows)
        try #require(metadata.browsingMetadata.tracks.count == rows - 1)
        let retirementIdentity = RouteIdentity(store)
        var populatedState = await state(store, provider: provider, queries: queries)
        populatedState["accountEpoch"] = session.accountEpoch
        populatedState["reconstructedRoutes"] = configuration.routes
        populatedState["retainedRowsExpected"] = rows <= 20_000 ? rows * configuration.routes : 0
        populatedState["retainedRouteRestorationVerified"] = rows <= 20_000
        populatedState["retirementOwnership"] = rows <= 20_000 ? "active-and-retained" : "active-oversized-only"
        populatedState["exportedEntities"] = rows - 1
        populatedState["collectionVersion"] = retirementIdentity.version.uuidString
        populatedState["firstRowID"] = retirementIdentity.firstID
        populatedState["lastRowID"] = retirementIdentity.lastID
        populatedState["firstOccurrenceUID"] = retirementIdentity.firstUID ?? ""
        populatedState["lastOccurrenceUID"] = retirementIdentity.lastUID ?? ""
        try await recorder.checkpoint("pre-account-retirement", state: populatedState)
        session.update(accountEpoch: 2, isAvailable: false)
        try await drainFixture(store, metadata: metadata, queries: queries)
        try #require(store.item == nil && store.tracks.isEmpty && metadata.browsingMetadata.tracks.isEmpty)
        var retiredState = await state(store, provider: provider, queries: queries)
        retiredState["accountEpoch"] = session.accountEpoch
        retiredState["retiredCollectionVersion"] = retirementIdentity.version.uuidString
        try await recorder.checkpoint("account-retirement", state: retiredState)
        return [
            "iterations": configuration.iterations, "routesInitiallyLoaded": configuration.routes,
            "preparationCPUSeconds": preparationCPU, "preparationWallSeconds": preparationWall,
            "reloadCPUSeconds": reloadCPU, "reloadWallSeconds": reloadWall,
            "reloads": configuration.oversizedSwitch ? configuration.iterations : 0,
            "retirementReconstructionCPUSeconds": retirementReloadCPU,
            "retirementReconstructionWallSeconds": retirementReloadWall,
            "retirementReconstructionRoutes": configuration.routes,
            "switchSemantics": configuration.oversizedSwitch ? "oversized-prepare-plus-reload" : configuration.workload,
            "retentionRouteLimit": 20, "retentionRowLimit": 20_000,
            "fixtureDuplicatesPerRoute": 1, "syntheticQueriesPublishEntities": false,
        ]
    }

    private func verifyAtomicSwitch(
        _ store: PlaylistStore, metadata: CatalogMetadataRepository, from old: CatalogItem, to new: CatalogItem
    ) throws {
        let oldURI = "spotify:track:\(old.id)-0"
        let newURI = "spotify:track:\(new.id)-0"
        let observations = HarnessCounters()
        withObservationTracking {
            _ = metadata.knownTrack(for: oldURI)
            _ = metadata.knownTrack(for: newURI)
        } onChange: { [weak metadata] in
            MainActor.assumeIsolated {
                observations.record(
                    metadata?.knownTrack(for: oldURI) != nil && metadata?.knownTrack(for: newURI) == nil
                        ? "old" : "mixed")
            }
        }
        store.prepare(new)
        try #require(observations.count("old") == 1 && observations.count("mixed") == 0)
        try #require(metadata.knownTrack(for: oldURI) == nil && metadata.knownTrack(for: newURI) != nil)
    }

    private func state(_ store: PlaylistStore, provider: HarnessCatalog, queries: HarnessCatalogQueries) async
        -> [String: Any]
    {
        [
            "activeRows": store.tracks.count, "selectedURI": store.loadedURI ?? "",
            "providerRequests": provider.playlistRequestCount, "activeQueries": await queries.activeQueryCount,
            "requestedEntityURIs": await queries.activeRequestedURIs.count,
        ]
    }

    private nonisolated static func item(_ id: String) -> CatalogItem {
        CatalogItem(id: id, uri: "spotify:playlist:\(id)", title: id, subtitle: "", artworkURL: nil, kind: .playlist)
    }

    private nonisolated static func makeRows(id: String, count: Int) -> [CatalogTrack] {
        (0..<count).map { index in
            let entity = index == count - 1 && count > 1 ? 0 : index
            return CatalogTrack(
                id: "row-\(id)-\(index)", uri: "spotify:track:\(id)-\(entity)", title: "Track \(entity)",
                artist: "Artist", album: "Album", duration: 180, artworkURL: nil, addedAt: HarnessDates.fixed,
                occurrenceUID: "occurrence-\(id)-\(index)")
        }
    }

    private func cpuSeconds() throws -> Double {
        var usage = rusage()
        try #require(getrusage(RUSAGE_SELF, &usage) == 0)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }

    private func seconds(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }

    @MainActor
    private final class Recorder {
        private let configuration: Configuration
        private let pid = getpid()
        private var phases: [[String: Any]] = []
        private var sequence = 0
        private var cleanupFailures: [[String: String]] = []

        init(_ configuration: Configuration) { self.configuration = configuration }

        // All runs complete exact native-host admission before memory/CPU checkpoints.
        // This bounds short 500-row workloads without extending a timed workload window.
        func admitNativeHost() async throws {
            let ready = configuration.report.appendingPathExtension("ready.json")
            let admitted = configuration.report.appendingPathExtension("admitted.json")
            guard !FileManager.default.fileExists(atPath: ready.path),
                !FileManager.default.fileExists(atPath: admitted.path)
            else { throw MeasurementFailure("Native admission paths already exist") }
            try write(["nonce": configuration.nonce, "pid": Int(pid)], to: ready)
            let value = try await waitForAcknowledgement(admitted, timeout: .seconds(10))
            guard Set(value.keys) == ["nonce", "pid"],
                value["nonce"] as? String == configuration.nonce,
                value["pid"] as? Int == Int(pid)
            else { throw MeasurementFailure("Native admission does not match this host") }
        }

        private func waitForAcknowledgement(_ url: URL, timeout: Duration) async throws -> [String: Any] {
            var data: Data?
            var readFailure: (any Error)?
            try await requireEventually(timeout: timeout, description: "Exact-PID controller acknowledgement") {
                guard FileManager.default.fileExists(atPath: url.path) else { return false }
                do {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    data = try handle.read(upToCount: 4097)
                } catch { readFailure = error }
                return true
            }
            if let readFailure { throw readFailure }
            guard let data, data.count <= 4096,
                let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw MeasurementFailure("Controller acknowledgement is malformed or oversized") }
            return value
        }

        func checkpoint(_ phase: String, state: [String: Any]) async throws {
            try Task.checkCancellation()
            sequence += 1
            var memory = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to: &memory) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            try #require(status == KERN_SUCCESS)
            var malloc = malloc_statistics_t()
            // The SDK declares a nil zone as the sum of statistics for all zones.
            malloc_zone_statistics(nil, &malloc)
            var usage = rusage()
            try #require(getrusage(RUSAGE_SELF, &usage) == 0)
            phases.append([
                "phase": phase, "sequence": sequence, "timeUnixSeconds": Date().timeIntervalSince1970,
                "residentBytes": memory.resident_size, "physicalFootprintBytes": memory.phys_footprint,
                "mallocBytesInUse": malloc.size_in_use, "mallocBytesReserved": malloc.size_allocated,
                "mallocBlocksInUse": malloc.blocks_in_use, "processPeakResidentBytes": usage.ru_maxrss,
                "processCPUSeconds": Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                    + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6,
                "state": state,
            ])
            guard let directory = configuration.gateDirectory else { return }
            let acknowledgement = directory.appendingPathComponent("ack-\(sequence).json")
            guard !FileManager.default.fileExists(atPath: acknowledgement.path) else {
                throw MeasurementFailure("Snapshot acknowledgement already exists")
            }
            try write(control(phase: phase, status: "waiting"), to: directory.appendingPathComponent("phase.json"))
            let value = try await waitForAcknowledgement(acknowledgement, timeout: .seconds(30))
            guard Set(value.keys) == ["version", "nonce", "pid", "phase", "sequence", "status"],
                value["version"] as? Int == 1,
                value["nonce"] as? String == configuration.nonce,
                value["pid"] as? Int == Int(pid),
                value["phase"] as? String == phase,
                value["sequence"] as? Int == sequence,
                value["status"] as? String == "captured"
            else { throw MeasurementFailure("Snapshot acknowledgement is malformed, stale, or failed") }
        }

        func finish(workload: [String: Any]) throws {
            try write(
                [
                    "version": 1, "status": "completed", "nonce": configuration.nonce, "pid": Int(pid),
                    "workload": configuration.workload, "tracksPerRoute": configuration.rows,
                    "attributionInstrumented": configuration.attribution,
                    "buildProfile": "optimized-debug-native-nonwmo", "debugBuild": true,
                    "debugHooksCompiled": true, "shippingBuild": false,
                    "optimizationEvidence":
                        "Controller must verify actual -O, testing, non-WMO, DEBUG and browsing compiler metadata; compile conditions alone do not prove optimization",
                    "os": ProcessInfo.processInfo.operatingSystemVersionString, "phases": phases, "result": workload,
                    "limits":
                        "Synthetic native test process; fixture/query/framework baselines are included. Resident, physical footprint and allocator bytes in use are distinct current observations. Peak RSS is cumulative. No whole-app or live-playback claim.",
                ], to: configuration.report)
            if let directory = configuration.gateDirectory {
                try write(
                    control(phase: "terminal", status: "completed"), to: directory.appendingPathComponent("phase.json"))
            }
        }

        func recordCleanupFailure(_ stage: String, error: Error) {
            cleanupFailures.append(["stage": stage, "error": String(describing: error)])
        }

        func fail(_ error: Error, fixtureOwnersReleased: Bool) {
            let failure: [String: Any] = [
                "version": 1, "status": "failed", "nonce": configuration.nonce,
                "pid": Int(pid), "error": String(describing: error), "phases": phases,
                "buildProfile": "optimized-debug-native-nonwmo", "debugBuild": true,
                "debugHooksCompiled": true, "shippingBuild": false,
                "fixtureOwnersReleased": fixtureOwnersReleased, "cleanupFailures": cleanupFailures,
            ]
            try? write(failure, to: configuration.report)
            if let directory = configuration.gateDirectory {
                try? write(
                    control(phase: "terminal", status: "failed"), to: directory.appendingPathComponent("phase.json"))
            }
        }

        private func control(phase: String, status: String) -> [String: Any] {
            [
                "version": 1, "nonce": configuration.nonce, "pid": Int(pid), "phase": phase,
                "sequence": sequence, "status": status, "workload": configuration.workload,
                "tracksPerRoute": configuration.rows,
            ]
        }

        private func write(_ value: [String: Any], to url: URL) throws {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        }
    }
}

private extension HarnessCatalogQueries {
    func memoryQueryIsSettled(expectedCount: Int, selectedTrackPrefix: String?) -> Bool {
        // Read count and membership in one actor turn. The temporary union is released
        // before returning; no expected URI set or fixture rows are held by this witness.
        guard activeQueryCount == 1 else { return false }
        let requested = activeRequestedURIs
        guard requested.count == expectedCount else { return false }
        // Oversized membership is a lexicographically sorted prefix of the route's URIs,
        // so route namespace plus bounded count excludes the equal-sized previous route.
        guard let selectedTrackPrefix else { return true }
        return requested.allSatisfy { $0.hasPrefix(selectedTrackPrefix) }
    }
}
