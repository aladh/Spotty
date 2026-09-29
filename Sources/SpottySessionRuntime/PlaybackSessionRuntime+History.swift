//
//  PlaybackSessionRuntime+History.swift
//  Spotty
//
//  Playback history and fewer-repeats ordering.
//

import SpottyDomain
import SpottyRuntimeContracts
import SpottyEngineAdapter
import Foundation
import OSLog

extension PlaybackSessionRuntime {
    func recordPlayed(_ uri: String) {
        guard !uri.isEmpty else { return }
        let playedAt = environment.clock.now()
        preferenceState.recordPlayed(uri, at: playedAt.timeIntervalSince1970, accountEpoch: accountEpoch)

        let track = catalogMetadata.knownTrack(for: uri)
        let info = catalogMetadata.displayInfo(for: uri)
        self.history.notePlayed(
            uri: uri,
            title: track?.title ?? info.title,
            artist: track?.artist ?? info.artist,
            artworkURL: track?.artworkURL,
            playedAt: playedAt
        )
    }

    func fewerRepeatsOrder(_ tracks: [CatalogTrack]) -> [CatalogTrack] {
        guard tracks.count > 1 else { return tracks }
        var generator = SystemRandomNumberGenerator()
        let order = ShufflePolicy.order(
            count: tracks.count,
            uri: { tracks[$0].uri },
            history: shuffleHistoryCache,
            now: environment.clock.now().timeIntervalSince1970,
            generator: &generator
        )
        return order.map { tracks[$0] }
    }
}
