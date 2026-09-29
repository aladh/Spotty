import SpottyRuntimeContracts
import Testing

struct CatalogSessionAdmissionChecks {
    @Test
    func retiredAccountCannotReactivateItsMutationAuthorization() throws {
        let admission = CatalogSessionAdmission(accountEpoch: 1)
        admission.updateAvailability(accountEpoch: 1, isAvailable: true)
        let oldAccount = PlaylistMutationContext(session: admission.snapshot)
        let oldAuthorization = try admission.authorize(oldAccount)
        admission.retire(nextAccountEpoch: 2)
        let unavailable = PlaylistMutationContext(session: admission.snapshot)
        admission.updateAvailability(accountEpoch: 1, isAvailable: true)
        #expect(throws: CancellationError.self) { try admission.authorize(oldAccount) }
        #expect(throws: CancellationError.self) { try admission.authorize(unavailable) }
        admission.updateAvailability(accountEpoch: 2, isAvailable: true)
        try admission.authorize(PlaylistMutationContext(session: admission.snapshot)).authorizeDispatch()
        #expect(throws: CancellationError.self) { try oldAuthorization.authorizeDispatch() }
    }
}
