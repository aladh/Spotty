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

    struct WindowQuery {
        let resultCode: Int32
        let arrayValue: Bool
        let windowCount: Int?

        func disposition() throws -> WindowDisposition {
            if resultCode == AXError.cannotComplete.rawValue { return .pending }
            guard resultCode == AXError.success.rawValue, arrayValue, let windowCount else {
                throw Failure(reason: "owned AX window query failed or returned an invalid value")
            }
            if windowCount == 0 { return .pending }
            guard windowCount == 1 else { throw Failure(reason: "owned AX window list is ambiguous") }
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
