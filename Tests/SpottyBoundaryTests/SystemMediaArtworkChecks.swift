import AppKit
import Foundation
import SpottyDomain
import SpottyRuntimeContracts
import Testing
@testable import SpottyCore

@Suite("System Now Playing artwork")
@MainActor
struct SystemMediaArtworkChecks {
    private let asset = ArtworkAsset(
        encodedThumbnail: Data(), rgbaPixels: Data([255, 0, 0, 255]),
        pixelWidth: 1, pixelHeight: 1, tint: nil)

    @Test func lateImagesCannotReplaceTheCurrentTrackAndMetadataDoesNotRestartLoading() async throws {
        let images = HarnessArtwork()
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(artwork: images))
        let output = HarnessSystemMediaOutput()
        let controls = SystemMediaControls(player: player, output: output)
        controls.start()
        defer { controls.stop() }
        present(player, uri: "a", title: "A", image: "a")
        try await requireEventually { await images.requests.count == 1 }
        #expect(output.snapshot?.title == "A")
        #expect(output.snapshot?.artwork == nil)
        #expect(output.snapshot?.canToggle == true)
        present(player, uri: "b", title: "B", image: "b")
        try await requireEventually { await images.requests.count == 2 }
        await images.complete(1, with: .success(asset))
        try await requireEventually { output.snapshot?.artwork != nil }
        let accepted = output.snapshot?.artwork
        await images.complete(0, with: .success(asset))
        present(player, uri: "b", title: "B corrected", image: "b", position: 15)
        try await requireEventually { output.snapshot?.title == "B corrected" }
        #expect(output.snapshot?.artwork === accepted)
        #expect(await images.requests.count == 2)
        #expect(output.snapshot?.artworkIdentity?.trackURI == "spotify:track:b")

        // Same track, new artwork is an immediate semantic change even between timing ticks.
        present(player, uri: "b", title: "B corrected", image: "b-new", position: 15.01)
        try await requireEventually { await images.requests.count == 3 }
        #expect(output.snapshot?.artwork == nil)
        await images.complete(2, with: .failure(ArtworkFailure.unavailable))
        present(player, uri: "b", title: "B corrected again", image: "b-new", position: 16)
        try await requireEventually { output.snapshot?.title == "B corrected again" }
        #expect(await images.requests.count == 3)
        #expect(output.snapshot?.canSkip == true)
        present(player, uri: "b", title: "No artwork", image: nil)
        try await requireEventually { output.snapshot?.title == "No artwork" }
        #expect(output.snapshot?.artwork == nil)
        await player.shutdownForTermination()
    }

    @Test(arguments: ["disconnect", "signout", "stop", "engine"])
    func lifetimeChangesClearArtworkAndRejectDelayedCompletion(change: String) async throws {
        let images = HarnessArtwork()
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(artwork: images))
        let output = HarnessSystemMediaOutput()
        let controls = SystemMediaControls(player: player, output: output)
        controls.start()
        defer { controls.stop() }
        present(player, uri: "a", title: "A", image: "a")
        try await requireEventually { await images.requests.count == 1 }
        await images.complete(0, with: .success(asset))
        try await requireEventually { output.snapshot?.artwork != nil }
        present(player, uri: "a", title: "A", image: "pending")
        try await requireEventually { await images.requests.count == 2 }
        #expect(output.snapshot?.artwork == nil)
        switch change {
        case "disconnect": player.send(.session(.recovering), source: .account)
        case "signout": await player.logout()
        case "stop": controls.stop()
        default:
            player.send(
                .engineConnection(EngineConnectionSnapshot(session: .ready, owner: .none, localDeviceID: nil)),
                source: .engineConnection,
                engineEpoch: player.engineGeneration + 1)
        }
        if change == "engine" {
            try await requireEventually { await images.requests.count == 3 }
            await images.complete(2, with: .failure(ArtworkFailure.unavailable))
        } else {
            try await requireEventually { output.snapshot == nil }
        }
        await images.complete(1, with: .success(asset))
        // A fresh accepted publication is a deterministic barrier for the old completion.
        if change != "stop" {
            present(player, uri: "next", title: "Next", image: nil)
            try await requireEventually { output.snapshot?.title == "Next" }
        }
        #expect(output.snapshot?.artwork == nil)
        await player.shutdownForTermination()
    }

    @Test func replacementAccountReloadsTheSameArtworkWithoutAcceptingOldPixels() async throws {
        let images = HarnessArtwork()
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(artwork: images))
        let output = HarnessSystemMediaOutput()
        let controls = SystemMediaControls(player: player, output: output)
        controls.start()
        defer { controls.stop() }
        present(player, uri: "same", title: "Same", image: "same")
        try await requireEventually { await images.requests.count == 1 }
        await player.logout()
        present(player, uri: "same", title: "Same", image: "same")
        try await requireEventually { await images.requests.count == 2 }
        let requests = await images.requests
        #expect(requests[0].accountEpoch != requests[1].accountEpoch)
        let replacement = ArtworkAsset(
            encodedThumbnail: Data(), rgbaPixels: Data([0, 0, 255, 255]),
            pixelWidth: 1, pixelHeight: 1, tint: nil)
        await images.complete(1, with: .success(replacement))
        try await requireEventually { output.snapshot?.artwork != nil }
        await images.complete(0, with: .success(asset))
        present(player, uri: "same", title: "Replacement", image: "same")
        try await requireEventually { output.snapshot?.title == "Replacement" }
        #expect(output.snapshot?.artwork?.asset.rgbaPixels == replacement.rgbaPixels)
        controls.stop()
        controls.start()
        try await requireEventually { await images.requests.count == 3 }
        #expect(output.snapshot?.artwork == nil)
        await images.complete(2, with: .failure(ArtworkFailure.unavailable))
        await player.shutdownForTermination()
    }

    @Test func nativeArtworkReturnsLoadedPixelsWithoutAURLOrDecoder() throws {
        let native = try #require(MacSystemMediaControlsOutput.makeArtwork(asset))
        #expect(native.bounds.size == NSSize(width: 1, height: 1))
        #expect(native.image(at: NSSize(width: 100, height: 100))?.size == NSSize(width: 1, height: 1))
        #expect(
            MacSystemMediaControlsOutput.makeArtwork(
                ArtworkAsset(encodedThumbnail: Data(), rgbaPixels: Data(), pixelWidth: 1, pixelHeight: 1, tint: nil))
                == nil)
    }

    private func present(_ player: PlaybackStore, uri: String, title: String, image: String?, position: Double = 5) {
        player.send(.session(.ready), source: .account)
        player.send(
            .presentation(
                PlaybackPresentationSnapshot(
                    currentTrack: CurrentTrack(
                        uri: "spotify:track:\(uri)", title: title, artist: "Artist",
                        artworkURL: image.flatMap { URL(string: "https://artwork.invalid/\($0)") },
                        duration: 200, metadataSource: .catalog),
                    transport: .paused,
                    timing: PlaybackTiming(position: position, duration: 200, anchoredAt: HarnessDates.fixed))),
            source: .user)
    }
}
