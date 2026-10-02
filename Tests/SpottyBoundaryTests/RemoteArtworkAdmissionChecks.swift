import AppKit
import SpottyRuntimeContracts
import SpottyTestSupport
import SwiftUI
import Testing
@testable import SpottyCore

@MainActor
struct RemoteArtworkAdmissionChecks {
    @Test func unchangedLoadedArtworkSurvivesVisibilityReadmission() async throws {
        let artwork = HarnessArtwork()
        let url = try #require(URL(string: "https://synthetic.invalid/artwork"))
        var observedAdmission: Bool?
        func content(_ admitted: Bool) -> some View {
            RemoteArtwork(url: url, kind: .album, cornerRadius: 4, geometryIdentifier: "artwork")
                .frame(width: 64, height: 64)
                .environment(\.artworkAccess, ArtworkAccess(provider: artwork, accountEpoch: 1))
                .environment(\.admitsArtwork, admitted)
                .onChange(of: admitted, initial: true) { _, value in observedAdmission = value }
        }
        let host = NSHostingView(rootView: content(true))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 64, height: 64), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        do {
            try await requireEventually { await artwork.requests.count == 1 }
            await artwork.complete(
                0,
                with: .success(
                    ArtworkAsset(
                        rgbaPixels: Data([255, 0, 0, 255]), pixelWidth: 1, pixelHeight: 1, tint: nil)))
            try await requireEventually {
                host.layoutSubtreeIfNeeded()
                return ShellGeometry.frames(in: window)["artwork.loaded"] != nil
            }
            host.rootView = content(false)
            try await requireEventually {
                host.layoutSubtreeIfNeeded()
                return observedAdmission == false
            }
            host.rootView = content(true)
            try await requireEventually {
                host.layoutSubtreeIfNeeded()
                return observedAdmission == true
            }
            // Drain cooperative native update work, then inspect the production loaded marker.
            for _ in 0..<20 { await Task.yield() }
            host.layoutSubtreeIfNeeded()
            #expect(await artwork.requests.count == 1, "visibility alone must not readmit a successful unchanged image")
            #expect(ShellGeometry.frames(in: window)["artwork.loaded"] != nil)
        } catch {
            for index in await artwork.requests.indices {
                await artwork.complete(index, with: .failure(ArtworkFailure.unavailable))
            }
            throw error
        }
        for index in await artwork.requests.indices {
            await artwork.complete(index, with: .failure(ArtworkFailure.unavailable))
        }
    }
}
