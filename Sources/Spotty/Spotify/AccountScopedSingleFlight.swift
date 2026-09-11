//
//  AccountScopedSingleFlight.swift
//  Spotty
//
//  Shared account- and selection-scoped request lifetime for catalog work.
//

import SpottyDomain
import Foundation
import os

/// Whether a second request for a key that is already in flight joins it or replaces it.
enum SingleFlightJoinPolicy: Sendable {
    /// A concurrent request for the same key and session awaits the running flight.
    case joinMatchingKey
    /// Every request opens a new scope and cancels the one it supersedes.
    case alwaysSupersede
}

/// Whether keys name independent lifetimes or one current selection.
enum SingleFlightScopePolicy: Sendable {
    /// Each key owns its own request scope and flight, and they run concurrently.
    case perKey
    /// One selection at a time: opening another key retires every earlier scope.
    case singleSelection
}

/// How much evidence a resumed continuation needs before it may publish.
enum SingleFlightPublishPolicy: Sendable {
    /// Request identity, account epoch, session revision, availability, and cancellation.
    case strict
    /// Account epoch, session revision, and availability only. A superseded or cancelled write
    /// may still have completed on the server, so its one reconciling read must not be dropped
    /// by a latest-intent gate that says nothing about session validity.
    case sessionOnly
}

/// Key for an owner that has exactly one request scope and no natural key.
enum SingleFlightUnitKey: Hashable, Sendable {
    case unit
}

/// Internal single-flight owner for account-scoped catalog work. It owns the request-scope
/// counter, the live task per key, cancel-previous, join-if-same-key-and-session, the
/// publish-if-current gate, and cancellation swallowing. Presentation state stays on the feature
/// store; this type publishes no UI.
@MainActor
final class AccountScopedSingleFlight<Key: Hashable & Sendable> {
    /// Identity captured before the first suspension of one request.
    struct Handle: Sendable {
        let key: Key
        let identity: AccountScopedRequestIdentity
        let sessionSnapshot: CatalogSessionSnapshot
    }

    /// Opaque waiter token. `awaitFlight` releases this claim on cancel or return.
    struct WaiterClaim: Sendable {
        fileprivate let key: Key
        fileprivate let flightID: UInt64
        fileprivate let claimID: UInt64
        fileprivate let task: Task<Void, Never>
    }

    enum Admission {
        case skip
        case join(WaiterClaim)
        case start(Handle)
    }

    private struct Flight: Sendable {
        let flightID: UInt64
        let task: Task<Void, Never>
        let session: CatalogSessionSnapshot
        var liveClaims: Set<UInt64>
    }

    private struct FlightState: Sendable {
        var flights: [Key: Flight] = [:]
    }

    private let session: CatalogSessionAvailability
    private let joinPolicy: SingleFlightJoinPolicy
    private let scopePolicy: SingleFlightScopePolicy
    private let publishPolicy: SingleFlightPublishPolicy
    private var nextRequestID: UInt64 = 0
    private var nextFlightID: UInt64 = 0
    private var nextClaimID: UInt64 = 0
    private var currentRequestIDs: [Key: UInt64] = [:]
    private var loadedSessions: [Key: CatalogSessionSnapshot] = [:]
    private let flightState = OSAllocatedUnfairLock(initialState: FlightState())

    init(
        session: CatalogSessionAvailability,
        join: SingleFlightJoinPolicy = .joinMatchingKey,
        scope: SingleFlightScopePolicy = .singleSelection,
        publish: SingleFlightPublishPolicy = .strict
    ) {
        self.session = session
        joinPolicy = join
        scopePolicy = scope
        publishPolicy = publish
    }

    /// Retires every scope and cancels every flight. Account replacement calls this.
    func reset() {
        nextRequestID &+= 1
        currentRequestIDs.removeAll(keepingCapacity: false)
        loadedSessions.removeAll(keepingCapacity: false)
        cancelFlights(matching: nil)
    }

    /// True when `key` already published in the current session and need not run again.
    func isLoaded(_ key: Key) -> Bool {
        guard let loaded = loadedSessions[key] else { return false }
        return loaded == session.snapshot
    }

    func markLoaded(_ handle: Handle) {
        guard owns(handle) else { return }
        loadedSessions[handle.key] = session.snapshot
    }

    /// Decides whether a request skips, joins the identical flight, or opens a new scope.
    /// `force` bypasses both the join and the already-loaded shortcut.
    func admit(_ key: Key, force: Bool = false) -> Admission {
        let currentSession = session.snapshot
        guard currentSession.isAvailable else { return .skip }
        if !force, joinPolicy == .joinMatchingKey {
            if let claim = joinExistingFlight(key: key, session: currentSession) {
                return .join(claim)
            }
            if isLoaded(key) { return .skip }
        }
        return .start(begin(key))
    }

    /// Opens a new request scope for `key`, retiring whatever it supersedes.
    @discardableResult
    func begin(_ key: Key) -> Handle {
        nextRequestID &+= 1
        let requestID = nextRequestID
        switch scopePolicy {
        case .singleSelection:
            currentRequestIDs.removeAll(keepingCapacity: true)
            loadedSessions.removeAll(keepingCapacity: true)
            cancelFlights(matching: nil)
        case .perKey:
            // Independent keys keep their own published memory: a superseded reload of one
            // section must not make the section look unloaded to a later request.
            cancelFlights(matching: key)
        }
        currentRequestIDs[key] = requestID
        return Handle(
            key: key,
            identity: session.requestIdentity(requestID: requestID),
            sessionSnapshot: session.snapshot
        )
    }

    /// Starts the flight and joins it as its first waiter.
    func run(_ handle: Handle, operation: @escaping @MainActor () async -> Void) async {
        let claim = register(handle, operation: operation, claimedByCaller: true)
        await withTaskCancellationHandler {
            await claim.task.value
        } onCancel: { [flightState] in
            Self.releaseClaim(claim, flightState: flightState)
        }
        Self.releaseClaim(claim, flightState: flightState)
    }

    /// Starts the flight without joining it. Fire-and-forget writes use this; because it has no
    /// waiter, nothing can join it and only a superseding scope cancels it.
    func start(_ handle: Handle, operation: @escaping @MainActor () async -> Void) {
        _ = register(handle, operation: operation, claimedByCaller: false)
    }

    func awaitFlight(_ claim: WaiterClaim) async {
        await withTaskCancellationHandler {
            await claim.task.value
        } onCancel: { [flightState] in
            Self.releaseClaim(claim, flightState: flightState)
        }
        Self.releaseClaim(claim, flightState: flightState)
    }

    /// Releases a scope that was opened but never started, so a later request is not refused.
    func abandonUnstarted(_ handle: Handle) {
        guard owns(handle) else { return }
        cancelFlights(matching: handle.key)
    }

    /// True while this handle still names the latest scope for its key.
    func owns(_ handle: Handle) -> Bool {
        currentRequestIDs[handle.key] == handle.identity.requestID
    }

    /// The publish gate. Pass `policy` to use the other named policy at one site.
    func isCurrent(_ handle: Handle, policy: SingleFlightPublishPolicy? = nil) -> Bool {
        switch policy ?? publishPolicy {
        case .strict:
            guard let requestID = currentRequestIDs[handle.key] else { return false }
            return handle.identity.isCurrent(
                requestID: requestID,
                accountEpoch: session.accountEpoch,
                sessionRevision: session.snapshot.revision,
                isAvailable: session.isAvailable,
                isCancelled: Task.isCancelled
            )
        case .sessionOnly:
            return handle.identity.accountEpoch == session.accountEpoch
                && handle.identity.sessionRevision == session.snapshot.revision
                && session.isAvailable
        }
    }

    /// Account-scoped cancellation is inert: it must never publish a user-facing error.
    func shouldReport(_ error: Error, for handle: Handle, policy: SingleFlightPublishPolicy? = nil) -> Bool {
        !isCancellation(error) && isCurrent(handle, policy: policy)
    }

    private func register(
        _ handle: Handle,
        operation: @escaping @MainActor () async -> Void,
        claimedByCaller: Bool
    ) -> WaiterClaim {
        nextFlightID &+= 1
        let flightID = nextFlightID
        nextClaimID &+= 1
        let ownerClaimID = nextClaimID
        let key = handle.key
        let task = Task { [weak self] in
            await operation()
            self?.completeFlight(key: key, requestID: handle.identity.requestID, flightID: flightID)
        }
        flightState.withLock { state in
            state.flights[key] = Flight(
                flightID: flightID,
                task: task,
                session: handle.sessionSnapshot,
                liveClaims: claimedByCaller ? [ownerClaimID] : []
            )
        }
        return WaiterClaim(key: key, flightID: flightID, claimID: ownerClaimID, task: task)
    }

    private func joinExistingFlight(
        key: Key,
        session currentSession: CatalogSessionSnapshot
    ) -> WaiterClaim? {
        nextClaimID &+= 1
        let claimID = nextClaimID
        return flightState.withLock { state -> WaiterClaim? in
            guard var flight = state.flights[key],
                flight.session == currentSession,
                !flight.task.isCancelled,
                !flight.liveClaims.isEmpty
            else {
                return nil
            }
            flight.liveClaims.insert(claimID)
            state.flights[key] = flight
            return WaiterClaim(key: key, flightID: flight.flightID, claimID: claimID, task: flight.task)
        }
    }

    private func completeFlight(key: Key, requestID: UInt64, flightID: UInt64) {
        guard currentRequestIDs[key] == requestID else { return }
        flightState.withLock { state in
            guard state.flights[key]?.flightID == flightID else { return }
            state.flights[key] = nil
        }
    }

    private func cancelFlights(matching key: Key?) {
        let stale = flightState.withLock { state -> [Task<Void, Never>] in
            if let key {
                guard let flight = state.flights.removeValue(forKey: key) else { return [] }
                return [flight.task]
            }
            let tasks = state.flights.values.map(\.task)
            state.flights.removeAll(keepingCapacity: false)
            return tasks
        }
        for task in stale { task.cancel() }
    }

    /// Releases one waiter. Cancels the underlying task only when the last live claim for that
    /// exact flight leaves. A stale claim is a no-op.
    ///
    /// `nonisolated` so cancellation handlers can run it without hopping to MainActor.
    private nonisolated static func releaseClaim(
        _ claim: WaiterClaim,
        flightState: OSAllocatedUnfairLock<FlightState>
    ) {
        let stale = flightState.withLock { state -> Task<Void, Never>? in
            guard var flight = state.flights[claim.key], flight.flightID == claim.flightID else {
                return nil
            }
            guard flight.liveClaims.remove(claim.claimID) != nil else {
                return nil
            }
            if flight.liveClaims.isEmpty {
                state.flights[claim.key] = nil
                return flight.task
            }
            state.flights[claim.key] = flight
            return nil
        }
        stale?.cancel()
    }
}
