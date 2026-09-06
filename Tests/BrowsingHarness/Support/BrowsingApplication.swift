import AppKit
import Darwin
import Foundation
import Observation
import SpottyDomain
import SwiftUI
@testable import SpottyCore

struct BrowsingLaunch: Codable {
    let runRoot: String
    let revision: String
    let diffSHA256: String
    let automated: Bool

    static func read() throws -> (Self, BrowsingScenario) {
        guard let root = Bundle.main.resourceURL,
            Bundle.main.bundleIdentifier == "dev.spotty.demo"
        else { throw BrowsingFailure.invalidScenario }
        let launch = try JSONDecoder().decode(
            Self.self, from: Data(contentsOf: root.appendingPathComponent("launch.json")))
        let scenario = try BrowsingScenario.decode(Data(contentsOf: root.appendingPathComponent("scenario.json")))
        guard launch.runRoot.hasPrefix("/"), FileManager.default.fileExists(atPath: launch.runRoot) else {
            throw BrowsingFailure.invalidScenario
        }
        return (launch, scenario)
    }
}

struct BrowsingSample: Codable {
    let checkpoint: String
    let elapsedSeconds: Double
    let loadSeconds: Double
    let residentBytes: UInt64
    let physicalFootprintBytes: UInt64
    let cpuSeconds: Double
    let scrollY: Double
    let documentHeight: Double

    @MainActor
    init(checkpoint: String, started: Date, loadSeconds: Double, scroll: NSScrollView?) throws {
        var memory = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &memory) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { throw BrowsingFailure.checkpoint("memory-sample") }
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw BrowsingFailure.checkpoint("cpu-sample") }
        self.checkpoint = checkpoint
        elapsedSeconds = Date().timeIntervalSince(started)
        self.loadSeconds = loadSeconds
        residentBytes = memory.resident_size
        physicalFootprintBytes = memory.phys_footprint
        cpuSeconds =
            Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        scrollY = Double(scroll?.contentView.bounds.origin.y ?? 0)
        documentHeight = Double(scroll?.documentView?.frame.height ?? 0)
    }
}

private struct BrowsingReport: Encodable {
    let version = 1
    let launch: BrowsingLaunch
    let scenario: BrowsingScenario
    let os: String
    let processorCount: Int
    let physicalMemoryBytes: UInt64
    let windowWidth: Double
    let windowHeight: Double
    let displayScale: Double
    let fixtureBytes: Int
    let demoCacheBytes: Int
    let networkSandboxVerified: Bool
    let samples: [BrowsingSample]
    let world: BrowsingWorld.Snapshot
    let passed: Bool
    let failure: String?
}

@MainActor
@Observable
final class BrowsingRun {
    let launch: BrowsingLaunch
    let world: BrowsingWorld
    let feedback: TransientFeedbackPresenter
    let player: PlaybackStore
    let navigation = CatalogNavigation()
    @ObservationIgnored private var workload: Task<Void, Never>?
    var status = "Preparing synthetic browsing"
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var samples: [BrowsingSample] = []
    @ObservationIgnored private var networkSandboxVerified = false
    @ObservationIgnored private weak var playlistScrollView: NSScrollView?

    init(launch: BrowsingLaunch, scenario: BrowsingScenario) throws {
        self.launch = launch
        world = try BrowsingWorld(
            scenario: scenario, artworkDirectory: URL(fileURLWithPath: launch.runRoot).appendingPathComponent("artwork")
        )
        let feedback = TransientFeedbackPresenter(clock: world)
        self.feedback = feedback
        player = PlaybackStore(environment: world.environment, feedback: feedback)
    }

    var items: [CatalogItem] { world.fixtures.playlists.compactMap(CatalogMapping.item(from:)) }

    func start() {
        guard launch.automated else { return }
        // The finite workload retains its app-owned model until the report is written.
        workload = Task { await perform() }
    }

    func perform() async {
        guard !hasStarted else { return }
        hasStarted = true
        defer { workload = nil }
        let started = Date()
        do {
            try verifyNetworkSandbox()
            networkSandboxVerified = true
            for _ in 0..<200 {
                if window() != nil, world.snapshot().requests["account.has-grant"] != nil,
                    player.accountStore.phase == (world.scenario.mode == .browsing ? .ready : .signedOut)
                {
                    break
                }
                try await ContinuousClock().sleep(for: .milliseconds(50))
            }
            guard window() != nil, world.snapshot().requests["account.has-grant"] != nil else {
                throw BrowsingFailure.checkpoint("window.startup")
            }
            await player.effects.settlement(of: .catalogLoad)?.wait()
            if world.scenario.mode == .signedOut {
                guard player.accountStore.phase == .signedOut else { throw BrowsingFailure.checkpoint("signed-out") }
                try await sample("signed-out.ready", started: started)
            } else {
                guard player.accountStore.phase == .ready,
                    player.catalog.homeLibrary.playlists.count == 2,
                    player.catalog.homeLibrary.homeSections.count == 1
                else { throw BrowsingFailure.checkpoint("home.ready") }
                try await sample("home.ready", started: started)
                for cycle in 1...world.scenario.cycles {
                    for index in items.indices {
                        let before = Date()
                        await player.catalog.playlistStore.load(items[index])
                        let loadSeconds = Date().timeIntervalSince(before)
                        guard player.catalog.playlistStore.tracks.count == world.scenario.trackCount,
                            player.catalog.playlistStore.error == nil
                        else { throw BrowsingFailure.checkpoint("playlist.ready") }
                        navigation.select(items[index])
                        playlistScrollView = try await waitForPlaylistScrollView(items[index].uri)
                        try await sample(
                            "cycle.\(cycle).playlist.\(index).ready", started: started, loadSeconds: loadSeconds)
                        for (step, fraction) in [0.25, 0.5, 0.75, 1.0, 0.0].enumerated() {
                            guard let scroll = playlistScrollView, let document = scroll.documentView else {
                                throw BrowsingFailure.checkpoint("playlist.scroll-view")
                            }
                            let height = max(0, document.frame.height - scroll.contentView.bounds.height)
                            guard height > 0 else { throw BrowsingFailure.checkpoint("playlist.scroll-range") }
                            let y = height * (document.isFlipped ? fraction : 1 - fraction)
                            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                            scroll.reflectScrolledClipView(scroll.contentView)
                            try await sample("cycle.\(cycle).playlist.\(index).scroll.\(step)", started: started)
                        }
                    }
                    navigation.updateSelection(.destination(.home))
                    try await sample("cycle.\(cycle).home.returned", started: started)
                }

            }
            let state = world.snapshot()
            guard state.mutationAttempts == 0 else {
                throw BrowsingFailure.checkpoint("read-only-isolation")
            }
            try await writeReport(failure: nil)
            status = "Completed — \(samples.count) checkpoints; report.json saved"
        } catch {
            status = error.localizedDescription
            try? await writeReport(failure: status)
        }
    }

    private func sample(_ checkpoint: String, started: Date, loadSeconds: Double = 0) async throws {
        status = checkpoint
        // The stores above provide readiness; this explicit cadence gives rendering and image
        // decoding the same viewing time on every run. It is not a network readiness heuristic.
        try await ContinuousClock().sleep(for: .milliseconds(world.scenario.dwellMilliseconds))
        window()?.contentView?.layoutSubtreeIfNeeded()
        window()?.displayIfNeeded()
        samples.append(
            try BrowsingSample(
                checkpoint: checkpoint, started: started, loadSeconds: loadSeconds,
                scroll: navigation.selection == .destination(.home) ? nil : playlistScrollView
            ))
    }

    private func window() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == "main" } ?? NSApp.mainWindow
    }

    /// Verify the operating-system guard before constructing any browsing workload. An
    /// accidental network transport could not open a socket in this process.
    private func verifyNetworkSandbox() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        if descriptor < 0 {
            guard errno == EPERM || errno == EACCES else { throw BrowsingFailure.checkpoint("network-sandbox") }
            return
        }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(9).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == -1, errno == EPERM || errno == EACCES else {
            throw BrowsingFailure.checkpoint("network-sandbox")
        }
    }

    private func waitForPlaylistScrollView(_ uri: String) async throws -> NSScrollView {
        let previous = playlistScrollView
        for _ in 0..<200 {
            window()?.contentView?.layoutSubtreeIfNeeded()
            if navigation.selection == .playlist(uri), player.catalog.playlistStore.loadedURI == uri,
                let root = window()?.contentView,
                let scroll = Self.findPlaylistScrollView(in: root), scroll !== previous,
                let document = scroll.documentView,
                document.frame.height > scroll.contentView.bounds.height,
                scroll.window != nil
            {
                return scroll
            }
            try await ContinuousClock().sleep(for: .milliseconds(50))
        }
        throw BrowsingFailure.checkpoint("playlist.view-ready")
    }

    /// Only playlist headers contain this production observer. TrackTable's per-playlist .id
    /// replaces its native list; readiness also rejects the previous destination's scroll view.
    static func findPlaylistScrollView(in root: NSView) -> NSScrollView? {
        if root is PlaylistScrollObserver.ObserverView { return root.enclosingScrollView }
        for child in root.subviews {
            if let scroll = findPlaylistScrollView(in: child) { return scroll }
        }
        return nil
    }

    private func writeReport(failure: String?) async throws {
        let window = window()
        let process = ProcessInfo.processInfo
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let cacheBytes = await BrowsingCacheMeasurement().bytes(at: cache)
        let report = BrowsingReport(
            launch: launch, scenario: world.scenario, os: process.operatingSystemVersionString,
            processorCount: process.processorCount, physicalMemoryBytes: process.physicalMemory,
            windowWidth: Double(window?.contentView?.bounds.width ?? 0),
            windowHeight: Double(window?.contentView?.bounds.height ?? 0),
            displayScale: Double(window?.backingScaleFactor ?? 0),
            fixtureBytes: world.fixtures.artworkBytes, demoCacheBytes: cacheBytes,
            networkSandboxVerified: networkSandboxVerified,
            samples: samples, world: world.snapshot(), passed: failure == nil, failure: failure
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(
            to: URL(fileURLWithPath: launch.runRoot).appendingPathComponent("report.json"), options: .atomic)
    }
}

/// Runs after all samples, off the UI actor. App Sandbox scopes this URL to the demo container.
private actor BrowsingCacheMeasurement {
    func bytes(at directory: URL?) -> Int {
        guard let directory,
            let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        return files.reduce(0) { result, entry in
            result + (((entry as? URL).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }) ?? 0)
        }
    }
}

private struct BrowsingApp: App {
    @NSApplicationDelegateAdaptor(SpottyAppDelegate.self) private var delegate
    @State private var run: BrowsingRun

    init() {
        do {
            let (launch, scenario) = try BrowsingLaunch.read()
            let run = try BrowsingRun(launch: launch, scenario: scenario)
            _run = State(initialValue: run)
            run.start()
        } catch {
            // This is a separate harness entry point: malformed configuration can never select live.
            fatalError(error.localizedDescription)
        }
    }

    var body: some Scene {
        SpottyScene(player: run.player, feedback: run.feedback, appDelegate: delegate, navigation: run.navigation)
    }
}

public enum BrowsingHarnessApplication {
    @MainActor
    public static func run() {
        do {
            _ = try BrowsingLaunch.read()
        } catch {
            FileHandle.standardError.write(Data(("Browsing harness: \(error.localizedDescription)\n").utf8))
            exit(2)
        }
        BrowsingApp.main()
    }
}
