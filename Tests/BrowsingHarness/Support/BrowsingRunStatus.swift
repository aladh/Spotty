import AppKit
import Foundation

/// Bounded Demo-only status. It contains no account, catalog, or accessibility text.
struct BrowsingRunStatus: Encodable {
    enum State: String, Encodable {
        case ready
        case measurementReady = "measurement-ready"
        case workloadRunning = "workload-running"
        case workloadFinished = "workload-finished"
        case failed
    }

    struct Window: Encodable {
        let visible: Bool
        let miniaturized: Bool
        let key: Bool
        let width: Double
        let height: Double
        let inspector: String
    }

    struct Display: Encodable {
        let scale: Double
        /// Display capability, never an assertion about observed callback or presentation cadence.
        let maximumFramesPerSecond: Int
        let reducedMotion: Bool
    }

    let schemaVersion = 1
    let runID: String
    let pid: Int32
    let state: State
    let failureCode: String?
    let window: Window
    let display: Display

    @MainActor
    init(launch: BrowsingLaunch, state: State, failureCode: String?, window: NSWindow?) {
        runID = launch.runID
        pid = ProcessInfo.processInfo.processIdentifier
        self.state = state
        self.failureCode = failureCode
        self.window = Window(
            visible: window?.occlusionState.contains(.visible) == true,
            miniaturized: window?.isMiniaturized ?? false,
            key: window?.isKeyWindow ?? false,
            width: Double(window?.contentView?.bounds.width ?? 0),
            height: Double(window?.contentView?.bounds.height ?? 0),
            inspector: Self.inspector(in: window))
        display = Display(
            scale: Double(window?.backingScaleFactor ?? 0),
            maximumFramesPerSecond: window?.screen?.maximumFramesPerSecond ?? 0,
            reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    @MainActor
    private static func inspector(in window: NSWindow?) -> String {
        guard let window else { return "unobserved" }
        var pending: [Any] = [window]
        var inspected = 0
        while let element = pending.popLast(), inspected < 10_000 {
            inspected += 1
            guard let accessible = element as? any NSAccessibilityProtocol else { continue }
            // Existing native tables expose these fixed labels. No user or fixture labels
            // leave this traversal, and absence cannot prove that the inspector is closed.
            switch accessible.accessibilityLabel() {
            case "Queue" where accessible.accessibilityRole() == .table: return "queue"
            case "Recently played" where accessible.accessibilityRole() == .table: return "history"
            default: break
            }
            pending.append(contentsOf: accessible.accessibilityChildren() ?? [])
        }
        return "unobserved"
    }
}
