import AppKit
import OSLog
import SwiftUI

enum AppDisplayName {
    static let fallback = "Spotty"

    static var current: String {
        resolve(info: Bundle.main.infoDictionary)
    }

    static func resolve(info: [String: Any]?) -> String {
        guard let displayName = info?["CFBundleDisplayName"] as? String,
            !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return fallback }
        return displayName
    }
}

@MainActor
final class SpottyAppDelegate: NSObject, NSApplicationDelegate {
    /// The app's content window, tracked so its close can be distinguished from
    /// menu and popover windows closing — those are windows too on macOS.
    private weak var trackedMainWindow: NSWindow?
    private var terminationHandler: (@MainActor () async -> Void)?
    private var terminationPending = false
    private var terminationShutdownTask: Task<Void, Never>?
    private var terminationTimeoutTask: Task<Void, Never>?

    func installTerminationHandler(_ handler: @escaping @MainActor () async -> Void) {
        terminationHandler = handler
    }

    func applicationWillFinishLaunching(_: Notification) {
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
    }

    func applicationDidFinishLaunching(_: Notification) {
        SpottyLog.lifecycle.info("Application finished launching")
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(windowDidBecomeMain(_:)),
            name: NSWindow.didBecomeMainNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    @objc private func windowDidBecomeMain(_ notification: Notification) {
        // Menus become key; they never become main. This is what makes the
        // window below Spotty's own content window.
        trackedMainWindow = notification.object as? NSWindow
        SpottyLog.ui.info("Main window became active")
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
            window === trackedMainWindow
        else { return }
        trackedMainWindow = nil
        SpottyLog.ui.info("Main window closed")
    }

    func applicationWillTerminate(_: Notification) {
        NotificationCenter.default.removeObserver(self)
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard let terminationHandler else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        SpottyLog.lifecycle.info("Application termination began")

        terminationShutdownTask = Task { [weak self] in
            await terminationHandler()
            self?.finishTermination()
        }
        terminationTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.finishTermination()
        }
        return .terminateLater
    }

    private func finishTermination() {
        guard terminationPending else { return }
        terminationPending = false
        terminationShutdownTask?.cancel()
        terminationTimeoutTask?.cancel()
        terminationShutdownTask = nil
        terminationTimeoutTask = nil
        NSApplication.shared.reply(toApplicationShouldTerminate: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }
}

struct SpottyApp: App {
    @NSApplicationDelegateAdaptor(SpottyAppDelegate.self) private var appDelegate
    @State private var player: PlaybackStore
    @State private var feedback: TransientFeedbackPresenter

    init() {
        let environment = PlaybackEnvironment.live
        let feedback = TransientFeedbackPresenter(clock: environment.clock)
        _feedback = State(initialValue: feedback)
        _player = State(initialValue: PlaybackStore(environment: environment, feedback: feedback))
    }

    var body: some Scene {
        SpottyScene(player: player, feedback: feedback, appDelegate: appDelegate)
    }
}

/// Live and isolated demo builds use the same window, root view, commands, and lifecycle.
struct SpottyScene: Scene {
    let player: PlaybackStore
    let feedback: TransientFeedbackPresenter
    let appDelegate: SpottyAppDelegate
    var navigation: CatalogNavigation?

    var body: some Scene {
        Window(AppDisplayName.current, id: "main") {
            RootView(player: player, catalog: player.catalog, feedback: feedback, navigation: navigation)
                .frame(minWidth: 960, minHeight: 640)
                .task {
                    appDelegate.installTerminationHandler { await player.shutdownForTermination() }
                    await player.restore()
                }
        }
        .defaultSize(width: 1220, height: 780)
        .defaultLaunchBehavior(.presented)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            InspectorCommands()
            AccountCommands(player: player)
            PlaybackCommands(player: player)
        }
    }
}

/// The package executable's deliberately narrow entry point. Keeping the scene
/// implementation in `SpottyCore` lets non-shipping checks exercise real app
/// boundaries without copying production code into a test-only target.
@MainActor
public func runSpottyApplication() {
    SpottyApp.main()
}
