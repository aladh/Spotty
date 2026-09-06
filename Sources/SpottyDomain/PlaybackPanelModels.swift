//
//  PlaybackPanelModels.swift
//  Spotty
//
//  Models behind the right-hand playback panel: repeat modes, queue entries,
//  Connect devices, and the local play history.
//

import Foundation

/// Advances the visible playhead between authoritative backend samples.
///
/// The backend remains the source of truth; this only avoids rendering its one-second samples
/// as visible steps. Paused positions never advance and every result stays within the track.
public func interpolatedPlaybackPosition(
    anchor: TimeInterval,
    anchoredAt: Date,
    now: Date,
    isPlaying: Bool,
    duration: TimeInterval
) -> TimeInterval {
    guard duration > 0 else { return max(0, anchor) }
    let elapsed = isPlaying ? max(0, now.timeIntervalSince(anchoredAt)) : 0
    return min(max(0, anchor + elapsed), duration)
}

/// Moves a Connect snapshot's position from Spotify's timestamp to the moment it was received.
/// Paused snapshots remain exact; playing snapshots can otherwise arrive minutes behind.
public func playbackSnapshotPosition(
    positionMilliseconds: Int64,
    durationMilliseconds: Int64,
    timestampMilliseconds: Int64?,
    isPlaying: Bool,
    now: Date = Date()
) -> TimeInterval {
    let position = max(0, positionMilliseconds)
    let elapsed: Int64
    if isPlaying, let timestampMilliseconds, timestampMilliseconds > 0 {
        let nowMilliseconds = Int64(now.timeIntervalSince1970 * 1_000)
        elapsed = max(0, nowMilliseconds - timestampMilliseconds)
    } else {
        elapsed = 0
    }
    let corrected = position + elapsed
    let bounded = durationMilliseconds > 0 ? min(corrected, durationMilliseconds) : corrected
    return TimeInterval(bounded) / 1_000
}

/// Repeat state, mirroring Spotify's off → context → track cycle.
public enum RepeatMode: Equatable, Sendable {
    case off
    case context
    case track

    /// Builds the mode from the backend's two independent repeat switches.
    public init(context: Bool, track: Bool) {
        self = track ? .track : (context ? .context : .off)
    }

    public var next: RepeatMode {
        switch self {
        case .off: .context
        case .context: .track
        case .track: .off
        }
    }

    public var symbolName: String {
        switch self {
        case .off, .context: "repeat"
        case .track: "repeat.1"
        }
    }

    public var accessibilityLabel: String {
        switch self {
        case .off: "Repeat off"
        case .context: "Repeat queue"
        case .track: "Repeat track"
        }
    }

    /// Repeat switches for the backend's two independent commands.
    public var flags: RepeatFlags {
        RepeatFlags(context: self == .context, track: self == .track)
    }
}

/// The backend models repeat as two independent booleans.
public struct RepeatFlags: Equatable, Sendable {
    public let context: Bool
    public let track: Bool

    public init(context: Bool, track: Bool) {
        self.context = context
        self.track = track
    }

    public func enabled(for flag: RepeatFlagMutation.Flag) -> Bool {
        switch flag {
        case .context: context
        case .track: track
        }
    }

    public func applying(_ mutation: RepeatFlagMutation) -> RepeatFlags {
        switch mutation.flag {
        case .context: RepeatFlags(context: mutation.enabled, track: track)
        case .track: RepeatFlags(context: context, track: mutation.enabled)
        }
    }
}

/// One Connect/FFI repeat switch. Spotify exposes context and track independently.
public struct RepeatFlagMutation: Equatable, Sendable {
    public enum Flag: Equatable, Sendable {
        case context
        case track
    }

    public let flag: Flag
    public let enabled: Bool

    public init(flag: Flag, enabled: Bool) {
        self.flag = flag
        self.enabled = enabled
    }
}

/// Forward mutations for one off → context → track → off step, plus compensation
/// for the only two-flag transition.
///
/// Only flags that differ from the captured previous state are sent. Repeat-queue
/// → repeat-track is the only two-flag step. Context is applied before track,
/// matching the existing Connect/FFI sequence; the intermediate account state is
/// off. If the track mutation fails after context was accepted, `compensation`
/// restores the captured previous flags (context on). This is a repeat-specific
/// plan, not a generic two-phase command framework.
public struct RepeatTransitionPlan: Equatable, Sendable {
    public let mutations: [RepeatFlagMutation]
    public let compensation: [RepeatFlagMutation]

    public init(mutations: [RepeatFlagMutation], compensation: [RepeatFlagMutation]) {
        self.mutations = mutations
        self.compensation = compensation
    }

    public static func planning(from previous: RepeatFlags, to next: RepeatFlags) -> RepeatTransitionPlan {
        var mutations: [RepeatFlagMutation] = []
        if previous.context != next.context {
            mutations.append(RepeatFlagMutation(flag: .context, enabled: next.context))
        }
        if previous.track != next.track {
            mutations.append(RepeatFlagMutation(flag: .track, enabled: next.track))
        }
        let compensation: [RepeatFlagMutation]
        if mutations.count > 1 {
            compensation = mutations.dropLast().map { mutation in
                RepeatFlagMutation(flag: mutation.flag, enabled: previous.enabled(for: mutation.flag))
            }
        } else {
            compensation = []
        }
        return RepeatTransitionPlan(mutations: mutations, compensation: compensation)
    }
}

/// One row in the queue panel. Queue updates carry uris only, so display names
/// resolve against the catalog at render time.
public struct QueueEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let uri: String
    public let provider: String
    public let occurrence: Int
    /// Connect occurrence uid when the authoritative snapshot supplied one.
    /// Empty for Web/non-authoritative presentation that has not bound a uid.
    public let uid: String

    public init(uri: String, provider: String, occurrence: Int = 0, uid: String = "") {
        id = Self.identity(occurrence: occurrence, provider: provider, uri: uri, uid: uid)
        self.uri = uri
        self.provider = provider
        self.occurrence = occurrence
        self.uid = uid
    }

    /// Selectable identity. A non-empty Connect uid is part of the id so a later
    /// snapshot with the same URI order cannot keep an old selection aimed at a
    /// different occurrence.
    public static func identity(occurrence: Int, provider: String, uri: String, uid: String) -> String {
        if uid.isEmpty {
            return "\(occurrence)-\(provider)-\(uri)"
        }
        return "\(occurrence)-\(uid)-\(provider)-\(uri)"
    }

    /// What fed this entry, in listener-facing words.
    public var sourceLabel: String {
        if provider == "web-api" { return "Up next" }
        if provider.contains("queue") { return "From your queue" }
        if provider.contains("autoplay") { return "Suggested by Spotify" }
        return "From the current context"
    }
}

/// One Spotify Connect device, as `/me/player/devices` spells it.
public struct ConnectDevice: Identifiable, Equatable, Sendable, Decodable {
    public let id: String
    public let name: String
    public let type: String
    public let isActive: Bool

    public init(id: String, name: String, type: String, isActive: Bool) {
        self.id = id
        self.name = name
        self.type = type
        self.isActive = isActive
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, type
        case isActive = "is_active"
    }

    public var symbolName: String {
        switch type.lowercased() {
        case "computer": "desktopcomputer"
        case "smartphone", "phone": "iphone"
        case "tablet": "ipad"
        case "tv": "tv"
        case "castaudio", "castvideo": "waveform"
        default: "hifispeaker"
        }
    }

    public func displayName(localDeviceID: String?) -> String {
        if id == localDeviceID { return "This Mac" }
        if isActive { return "\(name) (Playing)" }
        return name
    }
}

public enum ConnectCommandRoute: Equatable, Sendable {
    case local
    case remote(from: String, to: String)
    case waitingForLocalIdentity
    case needsDeviceSelection
}

/// Chooses the command destination without ever mistaking an unidentified remote for local
/// playback, which would transfer audio to this Mac as a side effect of pressing Play.
public func connectCommandRoute(
    isLocalActive: Bool,
    localDeviceID: String?,
    devices: [ConnectDevice],
    fallbackRemoteDeviceID: String? = nil
) -> ConnectCommandRoute {
    if isLocalActive { return .local }
    let target =
        devices.first(where: \.isActive)
        ?? fallbackRemoteDeviceID.flatMap { id in devices.first { $0.id == id } }
    guard let target else { return .local }
    if target.id == localDeviceID { return .local }
    guard let localDeviceID, !localDeviceID.isEmpty else { return .waitingForLocalIdentity }
    return .remote(from: localDeviceID, to: target.id)
}

/// Routes from the domain's explicit ownership snapshot. An uncertain remote candidate remains
/// routable (important for paused Connect devices), while an unidentified candidate never falls
/// through to local playback and unexpectedly steals the session.
public func connectCommandRoute(
    owner: PlaybackOwner,
    localDeviceID: String?
) -> ConnectCommandRoute {
    switch owner {
    case .none, .local:
        return .local
    case let .remote(device), let .uncertain(.some(device)):
        if device.id == localDeviceID { return .local }
        guard let localDeviceID, !localDeviceID.isEmpty else {
            return .waitingForLocalIdentity
        }
        return .remote(from: localDeviceID, to: device.id)
    case .uncertain(nil):
        guard let localDeviceID, !localDeviceID.isEmpty else { return .waitingForLocalIdentity }
        return .needsDeviceSelection
    }
}

/// One recently played track.
public struct HistoryEntry: Identifiable, Codable, Equatable, Sendable {
    public let uri: String
    public var title: String
    public var artist: String
    public var artworkURLString: String?
    public var playedAt: Date

    public init(uri: String, title: String, artist: String, artworkURLString: String?, playedAt: Date) {
        self.uri = uri
        self.title = title
        self.artist = artist
        self.artworkURLString = artworkURLString
        self.playedAt = playedAt
    }

    public var id: String { uri }

    public var artworkURL: URL? {
        artworkURLString.flatMap(URL.init(string:))
    }
}

/// Pure list transforms for the history store, so the retention rules are testable.
public enum PlaybackHistory {
    public static let cap = 10

    /// The list after `uri` finishes playing now. Consecutive replays move the
    /// existing entry to the front rather than duplicating it.
    public static func updated(
        _ entries: [HistoryEntry],
        afterPlaying uri: String,
        title: String,
        artist: String,
        artworkURLString: String?,
        playedAt: Date,
    ) -> [HistoryEntry] {
        let fresh = HistoryEntry(
            uri: uri,
            title: title,
            artist: artist,
            artworkURLString: artworkURLString,
            playedAt: playedAt
        )
        var updated = [fresh] + entries.filter { $0.uri != uri }
        if updated.count > cap {
            updated.removeLast(updated.count - cap)
        }
        return updated
    }

    /// Fills in metadata once it becomes known for a uri already in the list.
    public static func withMetadata(
        _ entries: [HistoryEntry],
        for uri: String,
        title: String,
        artist: String,
        artworkURLString: String?,
    ) -> [HistoryEntry] {
        entries.map { entry in
            guard entry.uri == uri else { return entry }
            var updated = entry
            if !title.isEmpty { updated.title = title }
            if !artist.isEmpty { updated.artist = artist }
            if updated.artworkURLString == nil { updated.artworkURLString = artworkURLString }
            return updated
        }
    }
}
