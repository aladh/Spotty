import Foundation
@testable import SpottyCore

struct QueueHydrationMeasurement: Codable {
    let wave: Int
    let tracks: Int
    let orderingMilliseconds: Double
    let firstMetadataMilliseconds: Double
    let completeMilliseconds: Double
    let starts: Int
    let joins: Int
    let cancellations: Int
    let publications: Int
    let metadataResults: Int

    /// New synthetic URIs prevent playlist/cache warming from eliminating concurrent hydration.
    /// Polling is a declared 5 ms measurement resolution and runs only in the isolated demo.
    @MainActor
    static func run(player: PlaybackStore, world: BrowsingWorld, wave: Int) async throws -> Self {
        let before = await player.queueService.refreshDiagnostics
        let started = ContinuousClock.now
        let prefix = "spotify:track:syntheticWave\(wave)x"
        func milliseconds() -> Double {
            let elapsed = started.duration(to: .now)
            return Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
        }
        func wait(_ name: String, for condition: () -> Bool) async throws {
            while !condition() {
                guard !Task.isCancelled, milliseconds() < 30_000 else { throw BrowsingFailure.checkpoint(name) }
                try await ContinuousClock().sleep(for: .milliseconds(5))
            }
        }
        world.playback.replaceQueueForMeasurement(wave: wave, count: 96)
        try await wait("queue.wave-order") {
            player.queueNextEntries.count == 96 && player.queueNextEntries.allSatisfy { $0.uri.hasPrefix(prefix) }
        }
        let order = milliseconds()
        player.refreshQueue()
        try await wait("queue.wave-first-metadata") {
            player.queueNextEntries.contains { player.catalog.metadata.knownTrack(for: $0.uri) != nil }
        }
        let first = milliseconds()
        try await wait("queue.wave-complete") {
            player.queueNextEntries.allSatisfy { player.catalog.metadata.knownTrack(for: $0.uri) != nil }
        }
        let complete = milliseconds()
        await player.effects.settlement(of: .queueRefresh)?.wait()
        let after = await player.queueService.refreshDiagnostics
        return Self(wave: wave, tracks: 96, orderingMilliseconds: order, firstMetadataMilliseconds: first,
            completeMilliseconds: complete, starts: after.starts - before.starts, joins: after.joins - before.joins,
            cancellations: after.cancellations - before.cancellations, publications: after.publications - before.publications,
            metadataResults: after.metadataResults - before.metadataResults)
    }
}
