//
//  DebugLog.swift
//  Spotty
//
//  Privacy-safe Unified Logging shared by debug and release builds.
//

import Foundation
import OSLog

public nonisolated enum SpottyLog {
    public static let subsystem = "dev.spotty.app"
    public static let account = Logger(subsystem: subsystem, category: "Account")
    public static let lifecycle = Logger(subsystem: subsystem, category: "Lifecycle")
    public static let playback = Logger(subsystem: subsystem, category: "Playback")
    public static let queue = Logger(subsystem: subsystem, category: "Queue")
    public static let catalog = Logger(subsystem: subsystem, category: "Catalog")
    public static let audio = Logger(subsystem: subsystem, category: "Audio")
    public static let commands = Logger(subsystem: subsystem, category: "Commands")
    public static let ui = Logger(subsystem: subsystem, category: "UI")
    public static let authentication = Logger(subsystem: subsystem, category: "Authentication")

    public static let accountSignposter = OSSignposter(logger: account)
    public static let queueSignposter = OSSignposter(logger: queue)
    public static let catalogSignposter = OSSignposter(logger: catalog)
    public static let audioSignposter = OSSignposter(logger: audio)

    public static func logger(for module: String) -> Logger {
        switch module {
        case "KeymasterAuth", "ClientToken": authentication
        case "AudioRenderer": audio
        case "QueueService": queue
        case "CatalogMetadataRepository", "PartnerAPI", "TrackAttributesAPI": catalog
        default: playback
        }
    }
}

#if DEBUG
    private nonisolated let iso8601FormatStyle = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true
    )
#endif

/// High-signal production diagnostics. Callers must pass a privacy-safe summary: never a token,
/// OAuth redirect, response body, or raw user payload. Dynamic fields are intentionally public so
/// the local `--telemetry` workflow is useful; the call sites constrain what those fields contain.
public nonisolated func debugLog(_ module: String, _ message: String) {
    SpottyLog.logger(for: module).info("\(message, privacy: .public)")

    #if DEBUG
        let timestamp = iso8601FormatStyle.format(Date())
        fputs("[\(timestamp) DEBUG \(module)] \(message)\n", stderr)
    #endif
}
