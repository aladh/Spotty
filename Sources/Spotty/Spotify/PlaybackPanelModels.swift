//
//  PlaybackPanelModels.swift
//  Spotty
//

import SpottyDomain
import Foundation

typealias RepeatMode = SpottyDomain.RepeatMode
typealias RepeatFlags = SpottyDomain.RepeatFlags
typealias QueueEntry = SpottyDomain.QueueEntry
typealias ConnectDevice = SpottyDomain.ConnectDevice
typealias ConnectCommandRoute = SpottyDomain.ConnectCommandRoute
typealias HistoryEntry = SpottyDomain.HistoryEntry
typealias PlaybackHistory = SpottyDomain.PlaybackHistory

/// The in-memory recently-played list shown in the panel's History tab.
/// Session-scoped by design: nothing about history needs to outlive the app.
@MainActor
@Observable
final class PlaybackHistoryStore {
    private(set) var entries: [HistoryEntry] = []

    func notePlayed(uri: String, title: String, artist: String, artworkURL: URL?, playedAt: Date) {
        guard uri.hasPrefix("spotify:track:") else { return }
        entries = PlaybackHistory.updated(
            entries,
            afterPlaying: uri,
            title: title.isEmpty ? fallbackTitle(for: uri) : title,
            artist: artist,
            artworkURLString: artworkURL?.absoluteString,
            playedAt: playedAt
        )
    }

    func applyMetadata(uri: String, title: String, artist: String, artworkURL: URL?) {
        entries = PlaybackHistory.withMetadata(
            entries,
            for: uri,
            title: title,
            artist: artist,
            artworkURLString: artworkURL?.absoluteString
        )
    }

    func replaceEntries(_ entries: [HistoryEntry]) {
        if self.entries != entries { self.entries = entries }
    }

    func reset() {
        entries = []
    }

    private func fallbackTitle(for uri: String) -> String {
        uri.split(separator: ":").last.map(String.init) ?? uri
    }
}
