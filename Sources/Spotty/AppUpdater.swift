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
    private var observations: [NSKeyValueObservation] = []
    private var started = false
    private(set) var canCheckForUpdates = false
    private(set) var automaticallyChecksForUpdates = false

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
        )
        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refreshState() }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refreshState() }
            },
        ]
    }

    private func refreshState() {
        // Read current values after the actor hop; queued notifications must not replay stale state.
        canCheckForUpdates = controller.updater.canCheckForUpdates
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
    }

    func start() {
        guard !started else { return }
        do {
            try controller.updater.start()
            started = true
        } catch {
            SpottyLog.lifecycle.error("Updater could not start: \(error.localizedDescription, privacy: .public)")
        }
    }

    func checkForUpdates() {
        guard controller.updater.canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }
}

struct UpdateCommands: Commands {
    let updater: AppUpdater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
            Toggle(
                "Automatically Check for Updates",
                isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.setAutomaticallyChecksForUpdates($0) }
                )
            )
        }
    }
}
