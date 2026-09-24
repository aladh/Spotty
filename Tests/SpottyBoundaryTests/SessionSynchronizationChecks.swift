import Foundation
import SpottyRuntimeContracts
import Testing
@testable import SpottyGateway
@testable import SpottySessionRuntime

@Suite("Session synchronization")
@MainActor
struct SessionSynchronizationTests {
    @Test
    func receiptCanCompleteWithNilAndRejectLaterResolutions() async {
        let receipt = KeymasterPersistenceReceipt<Int?>()
        receipt.resolve(nil)
        receipt.resolve(7)
        #expect(await receipt.value() == nil)
        #expect(await receipt.value() == nil)
    }

    @Test
    func concurrentReceiptWaitersAllReceiveTheFirstResolution() async {
        let receipt = KeymasterPersistenceReceipt<Int>()
        let values = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<32 {
                group.addTask { await receipt.value() }
            }
            group.addTask {
                receipt.resolve(7)
                receipt.resolve(9)
                return await receipt.value()
            }
            var values: [Int] = []
            for await value in group { values.append(value) }
            return values
        }
        #expect(values.count == 33)
        #expect(values.allSatisfy { $0 == 7 })
    }

    @Test
    func concurrentDispatchClaimsProduceOneReceipt() async {
        let clock = HarnessClock.sticky()
        let permit = PlaybackDispatchPermit(clock: clock)
        let claims = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<32 { group.addTask { permit.claim() } }
            var claims = 0
            for await claimed in group { if claimed { claims += 1 } }
            return claims
        }
        #expect(claims == 1)
        #expect(permit.isResolved)
        #expect(!permit.canDiscard)
        #expect(permit.takeDispatchReceipt() == clock.now())
        #expect(permit.takeDispatchReceipt() == nil)
        #expect(permit.canDiscard)
    }

    @Test(arguments: [false, true])
    func invalidationOnlyRevokesUnclaimedDispatch(claimFirst: Bool) {
        let clock = HarnessClock.sticky()
        let permit = PlaybackDispatchPermit(clock: clock)
        #expect(!permit.isResolved)
        #expect(!permit.canDiscard)
        if claimFirst { #expect(permit.claim()) }
        permit.invalidate()
        #expect(!permit.claim())
        #expect(permit.isResolved)
        #expect(permit.takeDispatchReceipt() == (claimFirst ? clock.now() : nil))
        #expect(permit.canDiscard)
    }

    @Test
    func retiredAccountCannotReactivateItsMutationAuthorization() throws {
        let admission = PlaylistMutationAdmission(accountEpoch: 1)
        let oldAccount = PlaylistMutationContext(accountEpoch: 1)
        let newAccount = PlaylistMutationContext(accountEpoch: 2)
        admission.activate(accountEpoch: 1)
        let oldAuthorization = try admission.authorize(oldAccount)
        admission.retire(nextAccountEpoch: 2)
        admission.activate(accountEpoch: 1)
        #expect(throws: CancellationError.self) { try admission.authorize(oldAccount) }
        #expect(throws: CancellationError.self) { try admission.authorize(newAccount) }
        admission.activate(accountEpoch: 2)
        try admission.authorize(newAccount).authorizeDispatch()
        #expect(throws: CancellationError.self) { try oldAuthorization.authorizeDispatch() }
    }
}
