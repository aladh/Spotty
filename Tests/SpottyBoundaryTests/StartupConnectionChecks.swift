import Testing
@testable import SpottyCore
@testable import SpottySessionRuntime

@Suite("Startup connection presentation")
@MainActor
struct StartupConnectionChecks {
    @Test(arguments: [false, true])
    func startupWaitsForSavedLoginBeforeOfferingConnect(hasGrant: Bool) async throws {
        let account = HarnessAccount(hasGrant: hasGrant)
        account.parkGrantRead = true
        let engine = HarnessEngine()
        let player = HarnessEnvironment.makePlaybackStore(HarnessEnvironment.make(engine: engine, account: account))
        defer { account.completeGrantRead() }
        #expect(player.phase == .connecting)
        #expect(CatalogPlaybackAccess(player: player).connectionLoadingLabel != nil)

        let restore = Task { await player.restore() }
        try await requireEventually { account.isGrantReadParked }
        #expect(player.phase == .connecting)
        #expect(engine.count(.initialize) == 0)
        #expect(account.authorizeCount == 0)

        account.completeGrantRead()
        await restore.value
        if hasGrant {
            #expect(engine.count(.initialize) == 1)
            #expect(player.phase == .connecting, "restoration still awaits the engine's ready observation")
            #expect(CatalogPlaybackAccess(player: player).connectionLoadingLabel != nil)
            player.withRuntime { _ = $0.send(.session(.ready), source: .account) }
            #expect(CatalogPlaybackAccess(player: player).connectionLoadingLabel == nil)
        } else {
            #expect(player.phase == .signedOut)
            #expect(CatalogPlaybackAccess(player: player).connectionLoadingLabel == nil)
        }
        await player.shutdownForTermination()
    }
}
