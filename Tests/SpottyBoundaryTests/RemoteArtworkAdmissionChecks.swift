import AppKit
import Observation
import SpottyRuntimeContracts
import SpottyTestSupport
import SwiftUI
import Testing
@testable import SpottyCore

@MainActor
struct RemoteArtworkAdmissionChecks {
    @Test(arguments: [false, true], [false, true])
    func pendingArtworkReadmitsAfterTheSameViewReappears(loadedBeforeHiding: Bool, detachHost: Bool) async throws {
        let artwork = HarnessArtwork()
        let url = try #require(URL(string: "https://synthetic.invalid/reappear"))
        let state = ArtworkAppearanceState()
        let host = NSHostingView(
            rootView: ArtworkAppearanceTabs(state: state, artwork: artwork, url: url, detachHost: detachHost))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 140), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        do {
            try await requireEventually { await artwork.requests.count == 1 }
            let image = ArtworkAsset(rgbaPixels: Data([0, 255, 0, 255]), pixelWidth: 1, pixelHeight: 1, tint: nil)
            if loadedBeforeHiding {
                await artwork.complete(0, with: .success(image))
                try await requireEventually {
                    host.layoutSubtreeIfNeeded()
                    return ShellGeometry.frames(in: window)["artwork.loaded"] != nil
                }
            }
            if detachHost { window.contentView = nil } else { state.selection = 1 }
            try await requireEventually { state.disappearances == 1 }
            if detachHost { window.contentView = host } else { state.selection = 0 }
            try await requireEventually { state.appearances == 2 }
            if !loadedBeforeHiding {
                try await requireEventually { await artwork.requests.count == 2 }
                await artwork.complete(1, with: .success(image))
            }
            try await requireEventually {
                host.layoutSubtreeIfNeeded()
                return ShellGeometry.frames(in: window)["artwork.loaded"] != nil
            }
            #expect(await artwork.requests.count == (loadedBeforeHiding ? 1 : 2))
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

    @Test(arguments: [false, true])
    func startedArtworkFinishesAcrossHidingWithoutReadmission(completeWhileHidden: Bool) async throws {
        let artwork = HarnessArtwork()
        let url = try #require(URL(string: "https://synthetic.invalid/pending"))
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
            host.rootView = content(false)
            try await requireEventually { observedAdmission == false }
            let image = ArtworkAsset(rgbaPixels: Data([0, 255, 0, 255]), pixelWidth: 1, pixelHeight: 1, tint: nil)
            if completeWhileHidden {
                await artwork.complete(0, with: .success(image))
                try await requireEventually {
                    host.layoutSubtreeIfNeeded()
                    return ShellGeometry.frames(in: window)["artwork.loaded"] != nil
                }
            }
            host.rootView = content(true)
            try await requireEventually { observedAdmission == true }
            if !completeWhileHidden { await artwork.complete(0, with: .success(image)) }
            try await requireEventually {
                host.layoutSubtreeIfNeeded()
                return ShellGeometry.frames(in: window)["artwork.loaded"] != nil
            }
            #expect(await artwork.requests.count == 1, "hiding cannot discard already admitted work")
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

    @Test func retiredHiddenRequestCannotReplaceTheVisibleAccountImage() async throws {
        let artwork = HarnessArtwork()
        let first = try #require(URL(string: "https://synthetic.invalid/first"))
        let second = try #require(URL(string: "https://synthetic.invalid/second"))
        var observedAdmission: Bool?
        func content(_ admitted: Bool, url: URL, epoch: UInt64) -> some View {
            RemoteArtwork(url: url, kind: .album, cornerRadius: 4, geometryIdentifier: "artwork")
                .frame(width: 64, height: 64)
                .environment(\.artworkAccess, ArtworkAccess(provider: artwork, accountEpoch: epoch))
                .environment(\.admitsArtwork, admitted)
                .onChange(of: admitted, initial: true) { _, value in observedAdmission = value }
        }
        let host = NSHostingView(rootView: content(true, url: first, epoch: 1))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 64, height: 64), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        do {
            try await requireEventually { await artwork.requests.count == 1 }
            host.rootView = content(false, url: second, epoch: 2)
            try await requireEventually { observedAdmission == false }
            #expect(await artwork.requests.count == 1, "hidden replacement must not admit artwork")
            host.rootView = content(true, url: second, epoch: 2)
            try await requireEventually { await artwork.requests.count == 2 }
            let requests = await artwork.requests
            #expect(requests[0].accountEpoch == 1 && requests[0].url == first)
            #expect(requests[1].accountEpoch == 2 && requests[1].url == second)
            let image = ArtworkAsset(rgbaPixels: Data([0, 255, 0, 255]), pixelWidth: 1, pixelHeight: 1, tint: nil)
            await artwork.complete(1, with: .success(image))
            try await requireEventually {
                host.layoutSubtreeIfNeeded()
                return ShellGeometry.frames(in: window)["artwork.loaded"] != nil
            }
            // The fixture ignores task cancellation; the old account settles after the replacement.
            await artwork.complete(0, with: .success(image))
            for _ in 0..<20 { await Task.yield() }
            host.layoutSubtreeIfNeeded()
            #expect(ShellGeometry.frames(in: window)["artwork.loaded"] != nil)
            #expect(await artwork.requests.count == 2)
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

@MainActor
@Observable
private final class ArtworkAppearanceState {
    var selection = 0
    var appearances = 0
    var disappearances = 0
}

@MainActor
private struct ArtworkAppearanceTabs: View {
    @Bindable var state: ArtworkAppearanceState
    let artwork: HarnessArtwork
    let url: URL
    let detachHost: Bool

    var body: some View {
        if detachHost {
            artworkContent
        } else {
            TabView(selection: $state.selection) {
                artworkContent.tabItem { Text("Artwork") }.tag(0)
                Color.clear.tabItem { Text("Away") }.tag(1)
            }
        }
    }

    private var artworkContent: some View {
        RemoteArtwork(url: url, kind: .album, cornerRadius: 4, geometryIdentifier: "artwork")
            .frame(width: 64, height: 64)
            .environment(\.artworkAccess, ArtworkAccess(provider: artwork, accountEpoch: 1))
            .environment(\.admitsArtwork, true)
            .onAppear { state.appearances += 1 }
            .onDisappear { state.disappearances += 1 }
    }
}
