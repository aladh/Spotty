import Foundation
import SpottyDomain
import SpottyRuntimeContracts

package enum RuntimeFeedbackKind: Equatable, Sendable { case success, informational, failure, dismiss }

package struct RuntimeFeedbackMessage: Equatable, Sendable {
    package let revision: UInt64
    package let kind: RuntimeFeedbackKind
    package let text: String
}

/// Equatable presentation values, prepared by the runtime. Reducer receipts, source watermarks,
/// pending-command payloads and rollback state never cross into the desktop's observation owner.
package struct RuntimePresentation: Equatable, Sendable {
    package let revision: UInt64
    package let semantic: PlaybackSemanticProjection
    package let timeline: PlaybackTiming
    package let queueEntries: [QueueEntry]
    package let devices: [ConnectDevice]
    package let localDeviceID: String?
    package let defaultLocalDevice: ConnectDevice?
    package let commandRoute: ConnectCommandRoute
    package let currentTrackIndicator: CurrentTrackIndicator
    package let playingContextURI: String?
    package let catalogPlaybackAvailability: CatalogPlaybackAvailability
    package let accountEpoch: UInt64
    package let engineGeneration: UInt64
    package let queueInspectorOrderingVersion: UInt64
    package let requiresReauthentication: Bool
    package let isTearingDown: Bool
    package let allowsCommands: Bool
    package let catalogSession: CatalogSessionSnapshot
    package let history: [HistoryEntry]
    package let metadata: [CatalogTrack]
    package let feedback: RuntimeFeedbackMessage?

    package static let initial = RuntimePresentation(
        revision: 0, semantic: PlaybackSemanticProjection(state: PlaybackState(accountEpoch: 1)),
        timeline: PlaybackTiming(anchoredAt: .distantPast), queueEntries: [], devices: [],
        localDeviceID: nil, defaultLocalDevice: nil, commandRoute: .local,
        currentTrackIndicator: CurrentTrackIndicator(), playingContextURI: nil,
        catalogPlaybackAvailability: CatalogPlaybackAvailability(state: PlaybackState(accountEpoch: 1)),
        accountEpoch: 1, engineGeneration: 0, queueInspectorOrderingVersion: 0,
        requiresReauthentication: false, isTearingDown: false, allowsCommands: true,
        catalogSession: CatalogSessionSnapshot(accountEpoch: 1, isAvailable: false), history: [], metadata: [],
        feedback: nil)
}

@SessionRuntimeActor
package final class RuntimeFeedback {
    package private(set) var message: RuntimeFeedbackMessage?
    private var revision: UInt64 = 0
    package var changed: (() -> Void)?

    package func success(_ text: String) { present(.success, text) }
    package func informational(_ text: String) { present(.informational, text) }
    package func failure(_ text: String) { present(.failure, text) }
    package func dismiss() { present(.dismiss, "") }

    private func present(_ kind: RuntimeFeedbackKind, _ text: String) {
        revision &+= 1
        message = RuntimeFeedbackMessage(revision: revision, kind: kind, text: text)
        changed?()
    }
}

@SessionRuntimeActor
package final class RuntimeHistory {
    package private(set) var entries: [HistoryEntry] = []
    package var changed: (() -> Void)?

    package func notePlayed(uri: String, title: String, artist: String, artworkURL: URL?, playedAt: Date) {
        guard uri.hasPrefix("spotify:track:") else { return }
        entries = PlaybackHistory.updated(
            entries, afterPlaying: uri,
            title: title.isEmpty ? uri.split(separator: ":").last.map(String.init) ?? uri : title,
            artist: artist, artworkURLString: artworkURL?.absoluteString, playedAt: playedAt)
        changed?()
    }

    package func applyMetadata(uri: String, title: String, artist: String, artworkURL: URL?) {
        entries = PlaybackHistory.withMetadata(
            entries, for: uri, title: title, artist: artist, artworkURLString: artworkURL?.absoluteString)
        changed?()
    }

    package func reset() { entries = []; changed?() }
}
