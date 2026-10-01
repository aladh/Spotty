import AppKit
import CoreGraphics
import Foundation

private struct DisplayRect: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = Double(rect.minX)
        y = Double(rect.minY)
        width = Double(rect.width)
        height = Double(rect.height)
    }
}

private struct DisplayMode: Codable, Equatable {
    let id: Int32
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double
    let desktopUsable: Bool

    init(_ mode: CGDisplayMode) {
        id = mode.ioDisplayModeID
        width = mode.width
        height = mode.height
        pixelWidth = mode.pixelWidth
        pixelHeight = mode.pixelHeight
        refreshRate = mode.refreshRate
        desktopUsable = mode.isUsableForDesktopGUI()
    }

    var eligible: Bool { desktopUsable && width >= 1280 && height >= 900 }
}

private struct DisplayScreen: Codable {
    let displayID: UInt32
    let frame: DisplayRect
    let visibleFrame: DisplayRect
    let backingScale: Double

    @MainActor init(_ screen: NSScreen) {
        displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        frame = DisplayRect(screen.frame)
        visibleFrame = DisplayRect(screen.visibleFrame)
        backingScale = Double(screen.backingScaleFactor)
    }
}

private struct DisplayReport: Encodable {
    let schemaVersion = 1
    let ownerPID = ProcessInfo.processInfo.processIdentifier
    var phase = "inspecting"
    var displayID: UInt32 = 0
    var originalMode: DisplayMode?
    var availableModes: [DisplayMode] = []
    var beforeScreens: [DisplayScreen] = []
    var selectedMode: DisplayMode?
    var observedMode: DisplayMode?
    var afterScreens: [DisplayScreen] = []
    var changed = false
    var failure: String?
    var restorationAttempted = false
    var restorationVerified = false
    var restoredMode: DisplayMode?
    var restorationFailure: String?
}

private enum DisplayFailure: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case .message(let text): text
        }
    }
}

/// An app-lifetime public Quartz mode selection, confined to an explicitly opted-in hosted runner.
/// CGDirectDisplay.h documents that CGDisplaySetDisplayMode reverts when its owning process exits.
@MainActor
private final class DisplayGuardian {
    private let reportURL: URL
    private var original: CGDisplayMode?
    private var report = DisplayReport()

    init(reportURL: URL) { self.reportURL = reportURL }

    private func write() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: reportURL, options: .atomic)
    }

    private func mode() throws -> CGDisplayMode {
        guard let mode = CGDisplayCopyDisplayMode(report.displayID) else {
            throw DisplayFailure.message("Current display mode is unavailable")
        }
        return mode
    }

    private func inspect() throws -> [CGDisplayMode] {
        _ = NSApplication.shared.setActivationPolicy(.prohibited)
        report.displayID = CGMainDisplayID()
        report.beforeScreens = NSScreen.screens.map(DisplayScreen.init)
        let modes = CGDisplayCopyAllDisplayModes(report.displayID, nil) as? [CGDisplayMode] ?? []
        report.availableModes = modes.map(DisplayMode.init)
        try write()  // Retain capacity even when the current mode or a suitable mode is unavailable.
        original = try mode()
        report.originalMode = original.map(DisplayMode.init)
        try write()
        return modes
    }

    private func restore() throws {
        report.restorationAttempted = true
        do {
            guard let original else { throw DisplayFailure.message("Original display mode was not captured") }
            if DisplayMode(try mode()) != DisplayMode(original) {
                let result = CGDisplaySetDisplayMode(report.displayID, original, nil)
                guard result == .success else {
                    throw DisplayFailure.message("Original display restoration failed: CGError \(result.rawValue)")
                }
            }
            report.restoredMode = DisplayMode(try mode())
            guard report.restoredMode == report.originalMode else {
                throw DisplayFailure.message("Observed display mode differs from the original after restoration")
            }
            report.restorationVerified = true
        } catch {
            report.restorationFailure = String(describing: error)
            throw error
        }
    }

    func run(inspectOnly: Bool) async throws {
        do {
            let modes = try inspect()
            if inspectOnly {
                report.phase = "inspected"
                try write()
                return
            }
            guard let original else { throw DisplayFailure.message("Original display mode is unavailable") }
            let selected: CGDisplayMode
            if DisplayMode(original).eligible {
                selected = original
            } else {
                let eligible = modes.filter { DisplayMode($0).eligible }.sorted {
                    let left = DisplayMode($0)
                    let right = DisplayMode($1)
                    return (left.width * left.height, left.pixelWidth * left.pixelHeight, left.id)
                        < (right.width * right.height, right.pixelWidth * right.pixelHeight, right.id)
                }
                guard let available = eligible.first else {
                    throw DisplayFailure.message(
                        "No advertised desktop display mode provides at least 1280x900 logical points")
                }
                selected = available
            }
            report.selectedMode = DisplayMode(selected)
            if DisplayMode(selected) != DisplayMode(original) {
                let result = CGDisplaySetDisplayMode(report.displayID, selected, nil)
                guard result == .success else {
                    throw DisplayFailure.message("Selected display mode failed: CGError \(result.rawValue)")
                }
                report.changed = true
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while true {
                report.observedMode = DisplayMode(try mode())
                report.afterScreens = NSScreen.screens.map(DisplayScreen.init)
                let screen = report.afterScreens.first { $0.displayID == report.displayID }
                if report.observedMode == report.selectedMode,
                    let screen, abs(screen.frame.width - Double(DisplayMode(selected).width)) <= 1,
                    abs(screen.frame.height - Double(DisplayMode(selected).height)) <= 1,
                    screen.visibleFrame.width >= 1080, screen.visibleFrame.height >= 752
                {
                    break
                }
                guard ContinuousClock.now < deadline else {
                    throw DisplayFailure.message(
                        "Selected mode and AppKit geometry did not stabilize with at least 1080x752 visible points")
                }
                try await ContinuousClock().sleep(for: .milliseconds(50))
            }
            report.phase = "ready"
            try write()
            guard readLine() == "restore" else {
                throw DisplayFailure.message("Display guardian control pipe closed before restoration was requested")
            }
            try restore()
            report.phase = "restored"
            try write()
        } catch {
            report.failure = String(describing: error)
            // Inspection is structurally read-only, including write failures and concurrent mode changes.
            if !inspectOnly && original != nil && !report.restorationVerified { try? restore() }
            report.phase = "failed"
            try? write()
            throw error
        }
    }
}

@main
private enum DisplayGuardianMain {
    @MainActor static func main() async {
        do {
            let arguments = CommandLine.arguments
            guard arguments.count == 3, ["--inspect", "--guard"].contains(arguments[1]) else {
                throw DisplayFailure.message("Usage: gui-display-guardian --inspect|--guard REPORT.json")
            }
            let inspectOnly = arguments[1] == "--inspect"
            if !inspectOnly {
                let environment = ProcessInfo.processInfo.environment
                guard environment["GITHUB_ACTIONS"] == "true", environment["CI"] == "true",
                    environment["RUNNER_ENVIRONMENT"] == "github-hosted", environment["RUNNER_OS"] == "macOS"
                else {
                    throw DisplayFailure.message(
                        "Display changes require an explicit GitHub-hosted macOS CI invocation")
                }
            }
            try await DisplayGuardian(reportURL: URL(fileURLWithPath: arguments[2])).run(inspectOnly: inspectOnly)
        } catch {
            FileHandle.standardError.write(Data(("Display guardian: \(error)\n").utf8))
            exit(1)
        }
    }
}
