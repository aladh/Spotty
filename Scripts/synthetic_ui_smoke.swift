import AppKit
import ApplicationServices
import Foundation

private struct SmokeFailure: Error {
    let category: String
    let message: String
}

private struct ReadOnlyEvidence: Codable {
    let commandCount: Int
    let mutationAttempts: Int
}

private struct SmokeResult: Encodable {
    let passed: Bool
    let category: String
    let message: String
    let checkpoints: [String]
    let runID: String?
    let pid: Int32?
    let baseline: ReadOnlyEvidence?
    let observed: ReadOnlyEvidence?
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
    let deadline = ContinuousClock.now.advanced(by: .seconds(120))
    var checkpoints: [String] = []
    var baseline: ReadOnlyEvidence?
    var observed: ReadOnlyEvidence?

    init(root: URL) throws {
        self.root = root.resolvingSymlinksInPath()
        identity = try JSONDecoder().decode(
            ProcessIdentity.self, from: Data(contentsOf: self.root.appendingPathComponent("process.json")))
        application = AXUIElementCreateApplication(identity.pid)
        try validateTarget()
    }

    /// Validate the owned run before every action; never discover a target by process name.
    func validateTarget() throws {
        try checkDeadline()
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
            scenario["version"] as? Int == 2,
            scenario["mode"] as? String == "browsing", scenario["guiShellRegression"] as? Bool == true,
            scenario["expandedLibrary"] as? Bool == true
        else {
            throw SmokeFailure(category: "target", message: "Only an owned interactive synthetic Demo run is allowed")
        }
        if baseline != nil { try assertReadOnly() }
    }

    private func json(_ url: URL) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw SmokeFailure(category: "target", message: "Invalid Demo launch metadata")
        }
        return value
    }

    private func readOnlyEvidence() throws -> ReadOnlyEvidence {
        let status = try json(root.appendingPathComponent("run-status.json"))
        guard status["schemaVersion"] as? Int == 1,
            status["runID"] as? String == identity.runID, status["pid"] as? Int32 == identity.pid,
            status["state"] as? String == "ready",
            let recordedAt = status["recordedAtSeconds"] as? Double,
            recordedAt.isFinite, Date().timeIntervalSince1970 - recordedAt >= -1,
            Date().timeIntervalSince1970 - recordedAt <= 3,
            status["networkSandboxVerified"] as? Bool == true,
            status["syntheticDependencies"] as? Bool == true,
            status["engineUsedForPlayback"] as? Bool == false,
            let commandCount = status["commandCount"] as? Int, commandCount >= 0,
            let mutationAttempts = status["mutationAttempts"] as? Int, mutationAttempts >= 0
        else {
            throw SmokeFailure(
                category: "isolation", message: "Fresh synthetic isolation/command status is unavailable")
        }
        let result = ReadOnlyEvidence(commandCount: commandCount, mutationAttempts: mutationAttempts)
        observed = result
        guard result.commandCount == 0, result.mutationAttempts == 0 else {
            throw SmokeFailure(
                category: "read-only", message: "The GUI fixture must have zero commands and mutation attempts")
        }
        return result
    }

    private func assertReadOnly() throws {
        let current = try readOnlyEvidence()
        guard let baseline, baseline.commandCount == 0, baseline.mutationAttempts == 0,
            current.commandCount == 0, current.mutationAttempts == 0
        else {
            throw SmokeFailure(
                category: "read-only", message: "Browsing must retain zero commands and mutation attempts")
        }
    }

    private func checkDeadline() throws {
        guard ContinuousClock.now < deadline else {
            throw SmokeFailure(category: "timeout", message: "UI smoke exceeded its 120-second action deadline")
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

    /// Traverse shell controls and visible rows, never dump the complete synthetic track collection.
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
            if try string(element, kAXRoleAttribute) == kAXTableRole {
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

    private func checkpoint(_ name: String) throws {
        if baseline != nil { try assertReadOnly() }
        checkpoints.append(name)
        try save(passed: false, category: "running", message: "Read-only UI smoke is running")
    }

    private func wait(_ name: String, until body: () throws -> AXUIElement?) throws -> AXUIElement {
        let end = ContinuousClock.now.advanced(by: .seconds(15))
        repeat {
            try checkDeadline()
            if let result = try body() {
                try checkpoint(name)
                return result
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while ContinuousClock.now < end
        throw SmokeFailure(category: "timeout", message: "Timed out waiting for \(name)")
    }

    private func unique(_ matches: [AXUIElement], _ label: String) throws -> AXUIElement? {
        guard matches.count <= 1 else {
            throw SmokeFailure(category: "ambiguous", message: "More than one Accessibility element matches \(label)")
        }
        return matches.first
    }

    private func button(_ root: AXUIElement, _ label: String, rows: Bool = false) throws -> AXUIElement {
        try wait("control.\(label)") {
            guard let element = try unique(matching(root, role: kAXButtonRole, label: label, rows: rows), label),
                try attribute(element, kAXEnabledAttribute) as? Bool == true
            else { return nil }
            return element
        }
    }

    private func press(_ root: AXUIElement, _ label: String, rows: Bool = false) throws {
        // Fixed browsing labels are the entire action surface: no transport, track activation or media keys.
        let allowed = [
            "Home", "Search", "Clear search", "Go back", "Go forward", "Expand Focus", "Collapse Focus",
            "All search results", "Songs search results", "Artists search results", "Albums search results",
            "Playlists search results", "Signals at Dusk, Harbor Lights",
        ]
        guard allowed.contains(label) else {
            throw SmokeFailure(category: "action", message: "Control is outside the read-only action allowlist")
        }
        let element = try button(root, label, rows: rows)
        try validateTarget()
        var actions: CFArray?
        guard AXUIElementCopyActionNames(element, &actions) == .success,
            (actions as? [String] ?? []).contains(kAXPressAction),
            AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
        else {
            throw SmokeFailure(category: "action", message: "The selected control does not support Accessibility press")
        }
    }

    private func table(_ window: AXUIElement, label: String, checkpoint: String) throws -> AXUIElement {
        try wait(checkpoint) {
            guard let table = try unique(matching(window, role: kAXTableRole, label: label), label),
                try !elements(table, kAXRowsAttribute).isEmpty
            else { return nil }
            return table
        }
    }

    private func select(_ row: AXUIElement) throws {
        try validateTarget()
        guard try string(row, kAXRoleAttribute) == kAXRowRole,
            AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success
        else {
            throw SmokeFailure(category: "action", message: "The native row does not support Accessibility selection")
        }
        _ = try wait("selection.native-row") {
            try attribute(row, kAXSelectedAttribute) as? Bool == true ? row : nil
        }
    }

    private func query(_ text: String, in window: AXUIElement, confirm: Bool = true) throws {
        let field = try wait("search.field") {
            try unique(matching(window, role: kAXTextFieldRole, label: "Search Spotify"), "Search Spotify")
        }
        try validateTarget()
        NSRunningApplication(processIdentifier: identity.pid)?.activate()
        guard AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else {
            throw SmokeFailure(category: "action", message: "Search field does not support Accessibility focus")
        }
        _ = try wait("search.field-focused") {
            try attribute(field, kAXFocusedAttribute) as? Bool == true ? field : nil
        }
        // The owned native field publishes AXValue changes through its existing text binding.
        // A semantic value change avoids keyboard modifier state and targets no other responder.
        try validateTarget()
        var settable = DarwinBoolean(false)
        guard try attribute(field, kAXFocusedAttribute) as? Bool == true,
            AXUIElementIsAttributeSettable(field, kAXValueAttribute as CFString, &settable) == .success,
            settable.boolValue,
            AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, text as CFString) == .success
        else {
            throw SmokeFailure(
                category: "action", message: "Search field does not support an Accessibility value change")
        }
        if confirm {
            _ = try wait("search.query-entered") {
                try string(field, kAXValueAttribute) == text ? field : nil
            }
        }
    }

    private func labeled(_ window: AXUIElement, _ label: String, checkpoint: String, rows: Bool = false) throws {
        _ = try wait(checkpoint) {
            try descendants(window, includingTableRows: rows).first { try hasLabel($0, label) }
        }
    }

    func run() throws {
        let window = try wait("startup.main-window") {
            let windows = try elements(application, kAXWindowsAttribute).filter {
                try string($0, kAXSubroleAttribute) == kAXStandardWindowSubrole
            }
            return try unique(windows, "main window")
        }
        _ = try wait("startup.isolated-ready") {
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent("run-status.json").path) else {
                return nil
            }
            baseline = try readOnlyEvidence()
            return window
        }
        try press(window, "Home")
        try labeled(window, "Made for the moment", checkpoint: "home.content-ready")
        try query("a", in: window)
        _ = try table(window, label: "Search results", checkpoint: "search.all-results")
        try press(window, "Artists search results")
        try labeled(window, "Harbor Lights, Artist", checkpoint: "search.artists")
        try query("Signals at Dusk", in: window)
        try press(window, "Albums search results")
        try labeled(window, "Signals at Dusk, Harbor Lights", checkpoint: "search.albums")
        try press(window, "Signals at Dusk, Harbor Lights")
        _ = try table(window, label: "Tracks", checkpoint: "detail.album-loaded")
        for cycle in 1...2 {
            try press(window, "Go back")
            try labeled(window, "Signals at Dusk, Harbor Lights", checkpoint: "history.\(cycle).search-restored")
            try press(window, "Go forward")
            _ = try table(window, label: "Tracks", checkpoint: "history.\(cycle).detail-restored")
        }
        try press(window, "Search")
        try query("Deep Work", in: window)
        try press(window, "Playlists search results")
        try labeled(window, "Deep Work, Mara Vale", checkpoint: "search.playlists")
        try query("Silver Lining", in: window)
        try press(window, "Songs search results")
        let songs = try table(window, label: "Songs", checkpoint: "search.songs")
        let song = try wait("search.song-row") {
            try elements(songs, kAXVisibleRowsAttribute).first { row in
                try descendants(row).contains { try hasLabel($0, "Silver Lining") }
            }
        }
        try select(song)
        try checkpoint("search.song-selected-without-activation")
        // Interrupt pending search work without waiting between these offered input changes.
        try query("Northern", in: window, confirm: false)
        try query("Harbor Lights", in: window, confirm: false)
        try press(window, "Clear search")
        _ = try wait("search.interrupted-clear") {
            guard
                let field = try unique(
                    matching(window, role: kAXTextFieldRole, label: "Search Spotify"), "Search Spotify"),
                try string(field, kAXValueAttribute).isEmpty,
                try !matching(window, role: kAXStaticTextRole, label: "Search Spotify").isEmpty,
                try matching(window, role: kAXTableRole, label: "Songs").isEmpty,
                try matching(window, role: kAXTableRole, label: "Tracks").isEmpty,
                try matching(window, role: kAXTableRole, label: "Search results").isEmpty
            else { return nil }
            return field
        }
        try query("Signals at Dusk", in: window)
        try press(window, "Albums search results")
        try labeled(window, "Signals at Dusk, Harbor Lights", checkpoint: "search.after-clear-recovered")
        try press(window, "Home")
        let library = try table(window, label: "Playlists", checkpoint: "library.ready")
        if try !matching(library, role: kAXButtonRole, label: "Collapse Focus", rows: true).isEmpty {
            try press(library, "Collapse Focus", rows: true)
        }
        try press(library, "Expand Focus", rows: true)
        let playlist = try wait("library.nested-playlist") {
            try elements(library, kAXRowsAttribute).prefix(60).first { row in
                try descendants(row).contains { try hasLabel($0, "Deep Work") }
            }
        }
        try select(playlist)
        _ = try table(window, label: "Tracks", checkpoint: "library.nested-playlist-loaded")
        try labeled(window, "Deep Work", checkpoint: "library.nested-playlist-title", rows: true)
        try validateTarget()
        // The interactive publisher must observe the completed action flow before success is emitted.
        let settledAfter = Date().timeIntervalSince1970 + 0.25
        _ = try wait("read-only.commands-unchanged") {
            let status = try json(root.appendingPathComponent("run-status.json"))
            guard let recordedAt = status["recordedAtSeconds"] as? Double, recordedAt >= settledAfter else {
                return nil
            }
            try assertReadOnly()
            return window
        }
    }

    func save(passed: Bool, category: String, message: String) throws {
        let result = SmokeResult(
            passed: passed, category: category, message: message, checkpoints: checkpoints,
            runID: identity.runID, pid: identity.pid, baseline: baseline, observed: observed)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(result)
        try data.write(to: root.appendingPathComponent("ui-smoke.json"), options: .atomic)
        if category != "running" { print(String(decoding: data, as: UTF8.self)) }
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
                        "Accessibility permission is required; the smoke does not request or change permissions. Screen Recording is not required."
                )
            }
            if argument == "--preflight" {
                emit(
                    SmokeResult(
                        passed: true, category: "permission", message: "Accessibility preflight passed",
                        checkpoints: [], runID: nil, pid: nil, baseline: nil, observed: nil))
                return
            }
            let runRoot = URL(fileURLWithPath: argument).resolvingSymlinksInPath()
            root = runRoot
            guard !FileManager.default.fileExists(atPath: runRoot.appendingPathComponent("ui-smoke.json").path) else {
                throw SmokeFailure(
                    category: "attempt", message: "This Demo run already has UI smoke evidence; use a fresh run")
            }
            let driver = try SyntheticUISmoke(root: runRoot)
            smoke = driver
            try driver.run()
            try driver.save(
                passed: true, category: "passed",
                message: "Read-only Home/Search/detail/history/library regression passed")
        } catch {
            let failure = error as? SmokeFailure
            let category = failure?.category ?? "target"
            let message = failure?.message ?? error.localizedDescription
            if let smoke {
                do { try smoke.save(passed: false, category: category, message: message) } catch {
                    emitFailure("Could not save UI smoke failure evidence", category: "result")
                }
            } else {
                let result = SmokeResult(
                    passed: false, category: category, message: message,
                    checkpoints: [], runID: nil, pid: nil, baseline: nil, observed: nil)
                // A repeated attempt must preserve the original run's evidence.
                emit(result, root: category == "attempt" ? nil : root)
            }
            exit(1)
        }
    }

    private static func emitFailure(_ message: String, category: String) {
        emit(
            SmokeResult(
                passed: false, category: category, message: message,
                checkpoints: [], runID: nil, pid: nil, baseline: nil, observed: nil))
    }

    private static func emit(_ result: SmokeResult, root: URL? = nil) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(result) else { return }
        if let root {
            do { try data.write(to: root.appendingPathComponent("ui-smoke.json"), options: .atomic) } catch {
                emitFailure("Could not save UI smoke evidence", category: "result")
                exit(1)
            }
        }
        print(String(decoding: data, as: UTF8.self))
    }
}
