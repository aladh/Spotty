import Foundation
import OSLog
import Observation
import Sparkle
import SwiftUI

/// The live app owns Sparkle separately from Spotify account and playback lifetimes.
@MainActor
@Observable
final class AppUpdater {
    private let controller: SPUStandardUpdaterController
    private var observation: NSKeyValueObservation?
    private var started = false
    private(set) var canCheckForUpdates = false

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
        )
        let updater = controller.updater
        observation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshState() }
        }
    }

    private func refreshState() {
        // Read current values after the actor hop; queued notifications must not replay stale state.
        canCheckForUpdates = controller.updater.canCheckForUpdates
    }

    func start() {
        guard !started else { return }
        let updater = controller.updater
        // Automatic checking is app policy, including installations that previously opted out.
        updater.automaticallyChecksForUpdates = true
        do {
            try updater.start()
            started = true
            // Sparkle supports an immediate background check before its scheduled cycle starts.
            updater.checkForUpdatesInBackground()
        } catch {
            SpottyLog.lifecycle.error("Updater could not start: \(error.localizedDescription, privacy: .public)")
        }
    }

    func checkForUpdates() {
        guard controller.updater.canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }
}

struct UpdateCommands: Commands {
    let updater: AppUpdater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
    }
}
