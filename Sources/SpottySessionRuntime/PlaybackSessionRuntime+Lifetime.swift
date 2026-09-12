//
//  PlaybackSessionRuntime+Lifetime.swift
//  Spotty
//
//  The single revalidation gate for suspended store work.
//

import SpottyDomain
import SpottyRuntimeContracts
import SpottyEngineAdapter
import Foundation

/// Which lifetime owners a resumed continuation must still match.
///
/// `.playback` is the default and compares both owners. `.account` is for the documented cases
/// where engine replacement is deliberately resolved somewhere else — the lifetime-stamped reducer
/// finish and the shared command follow-up — so a rebuilt engine must not silently discard an
/// outcome the reducer still has to reconcile.
enum PlaybackLifetimeScope {
    case account
    case playback
}

extension PlaybackSessionRuntime {
    /// The only sanctioned way to resume after an `await` in a store effect.
    ///
    /// Checks, in order: cooperative cancellation, session teardown, the process-termination gate,
    /// the captured account epoch, and — for `.playback` scope — the captured engine generation.
    /// `requiresConnection` additionally requires the accepted session to still be ready, and
    /// `route` requires the projected command destination to still be the captured one.
    ///
    /// Site-specific evidence (a captured track URI, a queue replacement token) is checked by the
    /// caller *after* this gate, never instead of it. Do not reintroduce ad hoc guard clusters:
    /// every omission at a call site is a lifetime hole that only shows up as a stale publication.
    func stillCurrent(
        _ lifetime: PlaybackLifetime,
        scope: PlaybackLifetimeScope = .playback,
        requiresConnection: Bool = false,
        route: ConnectCommandRoute? = nil
    ) -> Bool {
        guard !Task.isCancelled, !isTearingDown, terminationGate.allowsCommands else { return false }
        guard lifetime.accountEpoch == accountEpoch else { return false }
        if scope == .playback, lifetime.engineGeneration != engineGeneration { return false }
        if requiresConnection, !isConnected { return false }
        if let route, commandRoute != route { return false }
        return true
    }
}
