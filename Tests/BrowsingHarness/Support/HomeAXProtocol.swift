import AppKit
import ApplicationServices
import Darwin
import Foundation

/// Shared by the disposable Demo and separately compiled public AX controller.
enum HomeAXProtocol {
    struct Failure: Error { let reason: String }

    struct Request: Codable {
        let runID: String
        let pid: Int32
        let nonce: String
        let startedMachTime: UInt64
        let deadlineMachTime: UInt64

        func validate(runID: String, pid: Int32, now: UInt64) throws {
            var base = mach_timebase_info_data_t()
            guard mach_timebase_info(&base) == KERN_SUCCESS, base.numer > 0, base.denom > 0,
                self.runID == runID, self.pid == pid, UUID(uuidString: nonce) != nil,
                startedMachTime <= now, now < deadlineMachTime, deadlineMachTime > startedMachTime
            else { throw Failure(reason: "external request identity or clock invalid") }
            let seconds = Double(deadlineMachTime - startedMachTime) * Double(base.numer) / Double(base.denom) / 1e9
            guard seconds > 0, seconds <= 10 else { throw Failure(reason: "external deadline exceeds ten seconds") }
        }
    }

    enum WindowDisposition { case pending, ready }

    struct MeasuredWindow: Codable {
        let runID: String
        let nonce: String
        let pid: Int32
        let windowNumber: Int
        let identifier: String
        let appKitFrame: CGRect
        let primaryDisplayAppKitFrame: CGRect
        let axFrame: CGRect

        static func marker(runID: String, nonce: String) -> String { "spotty-home:\(runID):\(nonce)" }

        func validate(runID: String, nonce: String, pid: Int32) throws {
            guard self.runID == runID, self.nonce == nonce, self.pid == pid, windowNumber > 0,
                identifier == Self.marker(runID: runID, nonce: nonce),
                axFrame == (try HomeAXProtocol.axFrame(appKitFrame, primaryDisplay: primaryDisplayAppKitFrame))
            else { throw Failure(reason: "measured window identity or coordinate binding invalid") }
        }
    }

    struct WindowCandidate {
        let pid: Int32
        let role: String?
        let identifier: String?
        let frame: CGRect?
    }

    static func windowString(_ value: Any?) throws -> String? {
        guard let value else { return nil }
        guard let string = value as? String else { throw Failure(reason: "malformed public AX window string") }
        return string
    }

    /// Both frames are in AppKit screen points. AX uses the primary display's top left, with Y down.
    static func axFrame(_ frame: CGRect, primaryDisplay: CGRect) throws -> CGRect {
        guard validFrame(frame), validFrame(primaryDisplay) else {
            throw Failure(reason: "invalid measured window or primary display geometry")
        }
        return CGRect(
            x: frame.minX - primaryDisplay.minX, y: primaryDisplay.maxY - frame.maxY,
            width: frame.width, height: frame.height)
    }

    static func validFrame(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width.isFinite && frame.height.isFinite
            && frame.width > 0 && frame.height > 0
    }

    /// Identify first, then validate geometry. Other windows never compete based on their size.
    static func measuredWindowIndex(in candidates: [WindowCandidate], identity: MeasuredWindow) throws -> Int? {
        guard candidates.count <= 8 else { throw Failure(reason: "owned AX window inventory exceeds bound") }
        let matches = candidates.indices.filter {
            candidates[$0].pid == identity.pid && candidates[$0].role == NSAccessibility.Role.window.rawValue
                && candidates[$0].identifier == identity.identifier
        }
        guard matches.count <= 1 else { throw Failure(reason: "measured AX window identity is ambiguous") }
        guard let index = matches.first else { return nil }
        guard let frame = candidates[index].frame, validFrame(frame), frame == identity.axFrame else {
            throw Failure(reason: "identified AX window geometry differs from captured window")
        }
        return index
    }

    struct WindowQuery {
        let resultCode: Int32
        let arrayValue: Bool
        let windowCount: Int?

        func disposition(measuredIdentity: Bool = false) throws -> WindowDisposition {
            if resultCode == AXError.cannotComplete.rawValue { return .pending }
            guard resultCode == AXError.success.rawValue, arrayValue, let windowCount else {
                throw Failure(reason: "owned AX window query failed or returned an invalid value")
            }
            guard (0...8).contains(windowCount) else {
                throw Failure(reason: "owned AX window inventory exceeds bound")
            }
            if windowCount == 0 { return .pending }
            guard measuredIdentity || windowCount == 1 else {
                throw Failure(reason: "owned AX window list is ambiguous")
            }
            return .ready
        }
    }

    static func mayQueryWindows(sectionCount: Int?, expectedSections: Int, onHome: Bool, populatedAlready: Bool = false)
        throws -> Bool
    {
        guard onHome, [12, 120].contains(expectedSections),
            (sectionCount == 0 && !populatedAlready) || sectionCount == expectedSections
        else { throw Failure(reason: "Home changed or section readiness is invalid before AX window query") }
        return sectionCount == expectedSections
    }

    static func pulseIsFresh(recordedAt: Double?, now: Double) -> Bool {
        guard let recordedAt, recordedAt.isFinite, now.isFinite else { return false }
        return (-1...3).contains(now - recordedAt)
    }

    static func safetyPredicates(
        _ status: [String: Any], runID: String, pid: Int32, sections: Int,
        measurement: Bool, populatedAlready: Bool, now: Double
    ) -> [String: Bool] {
        let home = status["homeProbe"] as? [String: Any]
        let window = status["window"] as? [String: Any]
        return [
            "runID": status["runID"] as? String == runID,
            "pid": status["pid"] as? Int32 == pid,
            "state": ["ready", "workload-running", "workload-finished"].contains(status["state"] as? String ?? ""),
            "pulseFresh": pulseIsFresh(recordedAt: status["recordedAtSeconds"] as? Double, now: now),
            "networkDenied": status["networkSandboxVerified"] as? Bool == true,
            "syntheticDependencies": status["syntheticDependencies"] as? Bool == true,
            "engineUnused": status["engineUsedForPlayback"] as? Bool == false,
            "commandsZero": status["commandCount"] as? Int == 0,
            "mutationsZero": status["mutationAttempts"] as? Int == 0,
            "sectionsReadyOrInitialGate": home?["sectionCount"] as? Int == sections
                || (measurement && !populatedAlready && home?["sectionCount"] as? Int == 0),
            "connected": home?["connected"] as? Bool == true,
            "windowVisible": window?["visible"] as? Bool == true,
            "windowNotMiniaturized": window?["miniaturized"] as? Bool == false,
        ]
    }

    /// Passive waiting admits no AX query or action. Freshness stays mandatory for publication admission.
    static func mayWaitForPublicationPulse(
        _ status: [String: Any], predicates: [String: Bool], measurement: Bool,
        populatedAlready: Bool, now: Double
    ) -> Bool {
        guard measurement, !populatedAlready, predicates.count == 13,
            predicates.filter({ !$0.value }).map(\.key) == ["pulseFresh"],
            let recorded = status["recordedAtSeconds"] as? Double,
            recorded.isFinite, now.isFinite, now - recorded > 3,
            (status["homeProbe"] as? [String: Any])?["onHome"] as? Bool == true
        else { return false }
        return true
    }

    struct ControllerResult: Decodable {
        let runID: String
        let pid: Int32
        let nonce: String
        let passed: Bool
        let deadlineMachTime: UInt64

        func rejects(_ request: Request) -> Bool {
            !passed && runID == request.runID && pid == request.pid && nonce == request.nonce
                && deadlineMachTime == request.deadlineMachTime
        }
    }

    struct Observation: Codable {
        let nonce: String
        let observedMachTime: UInt64

        func validate(request: Request, loadStarted: UInt64, now: UInt64) throws {
            guard nonce == request.nonce, observedMachTime >= loadStarted,
                observedMachTime <= now, observedMachTime < request.deadlineMachTime
            else { throw Failure(reason: "external Home observation identity or clock invalid") }
        }
    }

    /// A completed temporary inode is linked into place atomically, without replacing evidence.
    static func publish(_ data: Data, to destination: URL, beforeCommit: (() throws -> Void)? = nil) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent("home-ax-publication-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        try beforeCommit?()
        guard link(temporary.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func isDetailTarget(
        role: String, title: String, label: String, enabled: Bool, frame: CGRect?, window: CGRect
    )
        -> Bool
    {
        guard role == NSAccessibility.Role.button.rawValue,
            title == "Synthetic album 0-0" || label == "Synthetic album 0-0", enabled,
            let frame, !frame.isEmpty, !window.isEmpty,
            frame.origin.x.isFinite, frame.origin.y.isFinite, frame.width.isFinite, frame.height.isFinite
        else { return false }
        return frame.intersects(window)
    }

    static func requireUniqueCount(_ count: Int) throws {
        guard (0...1).contains(count) else { throw Failure(reason: "ambiguous exact Home target") }
    }
}
