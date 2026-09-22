import AppKit
import ApplicationServices
import Foundation

private struct SmokeFailure: Error {
    let category: String
    let message: String
}

private struct SmokeResult: Encodable {
    let passed: Bool
    let category: String
    let message: String
    let checkpoints: [String]
}

private struct ProcessIdentity: Decodable {
    let runID: String
    let pid: Int32
    let executable: String
    let startIdentity: String
}

@MainActor
private final class SyntheticUISmoke {
    let root: URL
    let identity: ProcessIdentity
    let application: AXUIElement
    let deadline = Date().addingTimeInterval(75)
    var checkpoints: [String] = []

    init(root: URL) throws {
        self.root = root.resolvingSymlinksInPath()
        identity = try JSONDecoder().decode(
            ProcessIdentity.self, from: Data(contentsOf: root.appendingPathComponent("process.json")))
        application = AXUIElementCreateApplication(identity.pid)
        try validateTarget()
    }

    /// Validate the owned run before every action; never discover a target by process name.
    func validateTarget() throws {
        guard identity.pid > 0,
            let running = NSRunningApplication(processIdentifier: identity.pid),
            running.bundleIdentifier == "dev.spotty.demo", !running.isTerminated,
            let executable = running.executableURL?.resolvingSymlinksInPath(),
            executable.path == URL(fileURLWithPath: identity.executable).resolvingSymlinksInPath().path,
            let bundle = running.bundleURL, let resources = Bundle(url: bundle)?.resourceURL
        else {
            throw SmokeFailure(category: "target", message: "The run's PID is not its isolated Spotty Demo")
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(identity.pid), "-o", "lstart="]
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["LC_ALL": "C", "LANG": "C", "TZ": "UTC"], uniquingKeysWith: { _, value in value })
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
            String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).joined(separator: " ")
                == identity.startIdentity
        else { throw SmokeFailure(category: "target", message: "The Demo run's process identity changed") }
        let launch = try json(resources.appendingPathComponent("launch.json"))
        let manifest = try json(root.appendingPathComponent("manifest.json"))
        let scenario = try json(resources.appendingPathComponent("scenario.json"))
        guard launch["schemaVersion"] as? Int == 1,
            UUID(uuidString: identity.runID) != nil,
            launch["runID"] as? String == identity.runID,
            manifest["runID"] as? String == identity.runID,
            let recordedRoot = launch["runRoot"] as? String,
            URL(fileURLWithPath: recordedRoot).resolvingSymlinksInPath() == root,
            launch["automated"] as? Bool == false,
            (launch["engine"] as? [String: Any])?["usedForPlayback"] as? Bool == false,
            scenario["version"] as? Int == 2, scenario["mode"] as? String == "playback",
            scenario["expandedLibrary"] as? Bool == true
        else {
            throw SmokeFailure(
                category: "target", message: "Only the default interactive synthetic playback run is allowed")
        }
    }

    private func json(_ url: URL) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw SmokeFailure(category: "target", message: "Invalid Demo launch metadata")
        }
        return value
    }

    private func checkDeadline() throws {
        guard Date() < deadline else {
            throw SmokeFailure(category: "timeout", message: "UI smoke exceeded its 75-second action deadline")
        }
    }

    private func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef? {
        try checkDeadline()
        AXUIElementSetMessagingTimeout(element, 0.5)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        if result == .apiDisabled {
            throw SmokeFailure(category: "permission", message: "Accessibility access was revoked")
        }
        return result == .success ? value : nil
    }

    private func elements(_ element: AXUIElement, _ name: String) throws -> [AXUIElement] {
        try attribute(element, name) as? [AXUIElement] ?? []
    }

    private func string(_ element: AXUIElement, _ name: String) throws -> String {
        try attribute(element, name) as? String ?? ""
    }

    private func hasLabel(_ element: AXUIElement, _ label: String) throws -> Bool {
        for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            if try string(element, name) == label { return true }
        }
        return false
    }

    /// The first flow needs shell controls and visible library rows, not an unbounded track dump.
    private func descendants(_ root: AXUIElement, includingTableRows: Bool = false) throws -> [AXUIElement] {
        var pending = [root]
        var found: [AXUIElement] = []
        while let element = pending.popLast() {
            try checkDeadline()
            guard found.count < 1500 else {
                throw SmokeFailure(
                    category: "tree-limit", message: "Accessibility tree exceeded the smoke's bounded scope")
            }
            found.append(element)
            let role = try string(element, kAXRoleAttribute)
            if role == kAXTableRole {
                if includingTableRows {
                    pending.append(contentsOf: try elements(element, kAXVisibleRowsAttribute).prefix(60).reversed())
                }
            } else {
                pending.append(contentsOf: try elements(element, kAXChildrenAttribute).prefix(100).reversed())
            }
        }
        return found
    }

    private func matching(_ root: AXUIElement, role: String, label: String, rows: Bool = false) throws -> [AXUIElement]
    {
        try descendants(root, includingTableRows: rows).filter {
            try string($0, kAXRoleAttribute) == role && hasLabel($0, label)
        }
    }

    private func wait(_ checkpoint: String, until body: () throws -> AXUIElement?) throws -> AXUIElement {
        let end = Date().addingTimeInterval(15)
        repeat {
            try checkDeadline()
            if let result = try body() {
                checkpoints.append(checkpoint)
                return result
            }
            Thread.sleep(forTimeInterval: 0.15)
        } while Date() < end
        throw SmokeFailure(category: "timeout", message: "Timed out waiting for \(checkpoint)")
    }

    private func unique(_ matches: [AXUIElement], _ label: String) throws -> AXUIElement? {
        guard matches.count <= 1 else {
            throw SmokeFailure(category: "ambiguous", message: "More than one Accessibility element matches \(label)")
        }
        return matches.first
    }

    private func button(_ root: AXUIElement, _ label: String, rows: Bool = false) throws -> AXUIElement {
        try wait(label) {
            guard let element = try unique(matching(root, role: kAXButtonRole, label: label, rows: rows), label),
                try attribute(element, kAXEnabledAttribute) as? Bool == true
            else { return nil }
            return element
        }
    }

    private func press(_ element: AXUIElement) throws {
        try validateTarget()
        try checkDeadline()
        var actions: CFArray?
        guard AXUIElementCopyActionNames(element, &actions) == .success,
            (actions as? [String] ?? []).contains(kAXPressAction),
            AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
        else {
            throw SmokeFailure(category: "action", message: "The selected control does not support Accessibility press")
        }
    }

    func run() throws {
        let window = try wait("startup.main-window") {
            let windows = try elements(application, kAXWindowsAttribute).filter {
                try string($0, kAXSubroleAttribute) == kAXStandardWindowSubrole
            }
            return try unique(windows, "main window")
        }
        let library = try wait("startup.library") {
            try unique(matching(window, role: kAXTableRole, label: "Playlists"), "Playlists")
        }
        // A fresh process starts with collapsed folders; existing persisted Demo preferences remain untouched.
        try press(button(library, "Expand Focus", rows: true))
        let playlist = try wait("navigation.nested-playlist") {
            for row in try elements(library, kAXRowsAttribute) {
                if try descendants(row).contains(where: { try hasLabel($0, "Deep Work") }) { return row }
            }
            return nil
        }
        try validateTarget()
        guard AXUIElementSetAttributeValue(playlist, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success
        else {
            throw SmokeFailure(
                category: "action", message: "The nested playlist row does not support Accessibility selection")
        }
        _ = try wait("navigation.nested-playlist-loaded") {
            guard let table = try unique(matching(window, role: kAXTableRole, label: "Tracks"), "Tracks"),
                try !elements(table, kAXRowsAttribute).isEmpty,
                try descendants(window).contains(where: { try hasLabel($0, "Deep Work") })
            else { return nil }
            return table
        }
        try press(button(window, "Play"))
        try press(button(window, "Pause"))
        _ = try button(window, "Play")
        checkpoints.append("control.play-pause-restored")
    }
}

@main
private enum SyntheticUISmokeCommand {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments.dropFirst()
        var root: URL?
        var smoke: SyntheticUISmoke?
        do {
            guard arguments.count == 1, let argument = arguments.first else {
                throw SmokeFailure(category: "usage", message: "Usage: synthetic-ui-smoke --preflight|RUN_ROOT")
            }
            guard AXIsProcessTrusted() else {
                throw SmokeFailure(
                    category: "permission",
                    message:
                        "Enable Accessibility for the invoking terminal or Codex in System Settings > Privacy & Security > Accessibility, then rerun. Screen Recording is not required."
                )
            }
            if argument == "--preflight" {
                emit(
                    SmokeResult(
                        passed: true, category: "permission", message: "Accessibility preflight passed", checkpoints: []
                    ))
                return
            }
            let runRoot = URL(fileURLWithPath: argument).resolvingSymlinksInPath()
            root = runRoot
            let driver = try SyntheticUISmoke(root: runRoot)
            smoke = driver
            try driver.run()
            guard
                emit(
                    SmokeResult(
                        passed: true, category: "passed",
                        message: "Startup, nested playlist loading, and synthetic Play/Pause passed",
                        checkpoints: driver.checkpoints), root: root)
            else { exit(1) }
        } catch {
            let failure = error as? SmokeFailure
            emit(
                SmokeResult(
                    passed: false, category: failure?.category ?? "target",
                    message: failure?.message ?? error.localizedDescription, checkpoints: smoke?.checkpoints ?? []),
                root: root)
            exit(1)
        }
    }

    @discardableResult
    private static func emit(_ result: SmokeResult, root: URL? = nil) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(result) else { return false }
        if let root {
            do {
                try data.write(to: root.appendingPathComponent("ui-smoke.json"), options: .atomic)
            } catch {
                emit(
                    SmokeResult(
                        passed: false, category: "result",
                        message: "Could not save ui-smoke.json: \(error.localizedDescription)",
                        checkpoints: result.checkpoints))
                return false
            }
        }
        print(String(decoding: data, as: UTF8.self))
        return true
    }
}
