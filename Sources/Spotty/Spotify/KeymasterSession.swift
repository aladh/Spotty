//
//  KeymasterSession.swift
//  Spotty
//
//  Holds the keymaster tokens, and keeps them fresh.
//

import Foundation
import Synchronization

private typealias DefaultKeymasterTokenStore = KeymasterFileStore

/// The live keymaster grant: one access token, kept valid, shared by everything that needs it.
///
/// An actor because the token is read from several places at once — the accesspoint session,
/// pathfinder and spclient — and a refresh must happen once rather than once per caller.
/// Concurrent callers arriving during a refresh await the same one.
actor KeymasterSession {
    /// The app's grant. One instance, because one grant is what the app has: the accesspoint
    /// session and both API clients read the same token, and a second instance would refresh
    /// against a rotating token the first has already spent.
    static let shared = KeymasterSession()

    /// Async listeners waiting for a terminal grant revocation. The stream is instance-scoped:
    /// tests can construct an isolated session without ever notifying the live application.
    private nonisolated let revocationContinuations = Mutex<[UUID: AsyncStream<Void>.Continuation]>([:])

    /// Injected so the rotation policy can be tested without a network. The real one is
    /// `KeymasterAuth.refresh`.
    typealias Refresher = @Sendable (String) async throws -> KeymasterTokens

    /// A single bounded lane for blocking session-file operations. The worker is owned by
    /// this session rather than by an untracked detached task, so its ordering outlives every
    /// suspended token operation that submitted work to it.
    private let persistence: KeymasterPersistenceWorker
    private let refresher: Refresher
    /// Clears Spotify authentication cookies from the jar the token exchange uses.
    /// Injected so Sign Out cleanup can be checked without mutating the process-wide store.
    private let cookieCleanup: @Sendable () -> Void
    private var tokens: KeymasterTokens?
    private var loadFailure: KeymasterGrantLoadResult?
    /// A replacement grant is kept private until its durable save succeeds. Reads that could
    /// refresh or expose credentials wait for this bounded worker operation rather than racing a
    /// newer sign-in with the still-committed grant.
    private var adoptionInFlight: Int?
    private var adoptionCompletion: KeymasterPersistenceReceipt<Void>?
    private var hasLoadedStore = false
    /// Concurrent first callers join this rather than observing `hasLoadedStore` before the
    /// owned worker read has assigned `tokens`. The task includes the generation-guarded
    /// assignment, not only the disk read.
    private var storeLoadInFlight: Task<Void, Never>?
    private var refreshInFlight: Task<KeymasterTokens, Error>?
    /// Advanced by `supersedeRefresh()`. A refresh that was in flight when the grant was
    /// cleared or replaced must not write what it eventually returns — that would put the
    /// signed-out account's refresh token straight back into the session file.
    private var generation = 0

    init(
        store: KeymasterTokenStoring = DefaultKeymasterTokenStore(),
        refresher: @escaping Refresher = { try await KeymasterAuth.refresh(refreshToken: $0) },
        cookieCleanup: @escaping @Sendable () -> Void = {
            AuthCookieCleanup.removeSpotifyAuthenticationCookies()
        }
    ) {
        persistence = KeymasterPersistenceWorker(store: store)
        self.refresher = refresher
        self.cookieCleanup = cookieCleanup
    }

    /// Fires once when a refresh comes back `invalid_grant`. AsyncSequence keeps account
    /// lifecycle on the same structured-concurrency model as the rest of the application.
    nonisolated func grantRevocations() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream { continuation in
            revocationContinuations.withLock { $0[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.revocationContinuations.withLock { $0[id] = nil }
            }
        }
    }

    private func announceRevocation() {
        let continuations = revocationContinuations.withLock { Array($0.values) }
        for continuation in continuations { continuation.yield(()) }
    }

    /// Whether a grant has been completed on this machine.
    var hasGrant: Bool {
        get async {
            await grantState == .available
        }
    }

    /// Restores the distinction between a missing grant and a secure-store access failure for the
    /// account workflow. Callers must not start an implicit authorization when the latter occurs.
    var grantState: KeymasterGrantState {
        get async {
            await ensureGrantVisible()
            if tokens != nil { return .available }
            switch loadFailure {
            case .some(.denied): return .denied
            case .some(.failed): return .failed
            default: return .absent
            }
        }
    }

    /// Retries a previous secure-store failure when the user explicitly asks to connect again.
    /// A denied/unavailable read is cached for the current attempt so it cannot look absent, but
    /// it must not become a permanent process-lifetime result after file access recovers.
    func retryGrantState() async -> KeymasterGrantState {
        await waitForAdoption()
        if tokens == nil, loadFailure != nil {
            hasLoadedStore = false
            loadFailure = nil
        }
        return await grantState
    }

    /// Whether the persisted grant must not be reused for streaming on the next connection.
    /// The marker lives with the grant so a relaunch cannot lose a typed engine rejection.
    func reauthenticationRequired() async -> Bool {
        await ensureGrantVisible()
        return tokens?.requiresReauthentication == true
    }

    /// Retains the Web API grant while durably marking its streaming credentials unusable. The
    /// save is submitted on the owned worker before the actor suspends, so a concurrent refresh
    /// or sign-out cannot write an older grant after this marker decision.
    func markReauthenticationRequired() async {
        let requestedGeneration = generation
        await ensureGrantVisible()
        guard generation == requestedGeneration else { return }

        // Let a refresh that already owns the grant settle before taking its snapshot. Cancelling
        // it and saving the pre-refresh value could otherwise put an older rotating refresh token
        // after the refresh's durable write on the worker.
        if let refreshInFlight {
            _ = try? await refreshInFlight.value
        }
        await waitForAdoption()
        guard generation == requestedGeneration, let current = tokens else { return }

        supersedeRefresh()
        let startedAt = generation
        var marked = current
        marked.requiresReauthentication = true
        // Keep the in-memory marker visible while the save is pending. A refresh that starts
        // during this await then carries the marker forward instead of overwriting it with a
        // response built from the old in-memory grant. A failed marker write remains actionable
        // for this process; a fresh adoption or explicit grant clear is required to change it.
        tokens = marked
        let receipt = persistence.submitSave(marked)
        let result = await receipt.value()
        guard generation == startedAt else { return }
        guard case .success = result else {
            SpottyLog.authentication.error(
                "\(KeymasterGrantPersistenceDiagnostics.saveFailed, privacy: .public)"
            )
            return
        }
    }

    /// Loads persisted state lazily on this actor rather than synchronously while the main-actor
    /// controller is being initialized. A file lookup can take time to resolve an older
    /// item's ACL; that must not prevent SwiftUI from presenting the window.
    ///
    /// The load itself is a single flight: `hasLoadedStore` is not set until the read finishes,
    /// so a concurrent early `accessToken()` cannot observe an empty grant and throw `noGrant`
    /// while the store still holds one. `adopt` and `clear` bump `generation` and win over a
    /// stale read the same way a superseded refresh does.
    private func ensureGrantVisible() async {
        await waitForAdoption()
        await loadStoredGrantIfNeeded()
        // An adoption can begin while the initial read is suspended.
        await waitForAdoption()
    }

    private func loadStoredGrantIfNeeded() async {
        if hasLoadedStore { return }

        if let storeLoadInFlight {
            await storeLoadInFlight.value
            return
        }

        let startedAt = generation
        let task = Task {
            await self.commitStoreLoad(startedAt: startedAt)
        }
        storeLoadInFlight = task
        defer {
            if storeLoadInFlight == task {
                storeLoadInFlight = nil
            }
        }
        await task.value
    }

    private func commitStoreLoad(startedAt: Int) async {
        let receipt = persistence.submitLoad()
        let result = await receipt.value()
        applyLoadedGrant(result, startedAt: startedAt)
    }

    /// Only the in-flight load task assigns. Joiners wait for that task so they cannot observe
    /// `tokens == nil` after the disk read has finished. Adopt/clear bump `generation` and set
    /// `hasLoadedStore` first, so a stale snapshot is discarded.
    private func applyLoadedGrant(_ result: KeymasterGrantLoadResult, startedAt: Int) {
        guard generation == startedAt, !hasLoadedStore else { return }
        tokens = result.tokens
        loadFailure =
            switch result {
            case .denied, .failed: result
            default: nil
            }
        hasLoadedStore = true
    }

    /// Records the outcome of a fresh grant.
    func adopt(_ newTokens: KeymasterTokens) async throws {
        hasLoadedStore = true
        supersedeRefresh()
        let startedAt = generation
        adoptionInFlight = startedAt
        let completion = KeymasterPersistenceReceipt<Void>()
        adoptionCompletion = completion
        var committed = newTokens
        committed.requiresReauthentication = false
        defer {
            completion.resolve(())
        }
        do {
            let receipt = persistence.submitSave(committed)
            let result = await receipt.value()
            try result.get()
        } catch {
            // A newer grant or sign-out owns persistence now. The worker serializes those writes
            // after this one, so this stale failure must not replace their outcome or reach UI.
            guard generation == startedAt, adoptionInFlight == startedAt else { return }
            adoptionInFlight = nil
            adoptionCompletion = nil
            throw error
        }
        guard generation == startedAt, adoptionInFlight == startedAt else { return }
        // Commit memory only after the worker confirms the durable replacement. This leaves the
        // last committed grant available while a save is blocked and avoids rolling back to a
        // newer grant that never reached the store when two saves fail in succession.
        tokens = committed
        loadFailure = nil
        adoptionInFlight = nil
        adoptionCompletion = nil
    }

    /// Forgets the grant — on logout, or when the refresh token is dead.
    func clear() async {
        hasLoadedStore = true
        supersedeRefresh()
        adoptionInFlight = nil
        let supersededAdoption = adoptionCompletion
        adoptionCompletion = nil
        supersededAdoption?.resolve(())
        let expectedGeneration = generation
        tokens = nil
        loadFailure = nil
        let receipt = persistence.submitClear()
        _ = await receipt.value()
        // A new grant may have been adopted while the bounded worker completed the clear. Its
        // cookies belong to the replacement and must survive; the worker's ordering still makes
        // this clear happen before that replacement's save.
        guard generation == expectedGeneration else { return }
        cookieCleanup()
    }

    /// Abandons any refresh in flight and disowns whatever it eventually returns.
    ///
    /// A refresh spends the *previous* refresh token, and Spotify keeps one live token per
    /// client id and account — so a refresh that started before a new grant either returns
    /// tokens that grant has already replaced, and overwrites it, or is refused as
    /// `invalid_grant` for the token it retired, and discards it. The second is the likelier of
    /// the two and logs the user out moments after they authorized. Re-authorizing while signed
    /// in is a real path here: Speakers and the play alert both offer it.
    ///
    /// Cancellation is cooperative, so the network call can still succeed afterwards; the
    /// generation is what stops its result from being written.
    private func supersedeRefresh() {
        generation &+= 1
        refreshInFlight?.cancel()
        refreshInFlight = nil
    }

    /// A token that is valid now, refreshing first if it is close enough to expiry.
    ///
    /// Throws rather than returning nil when there is no grant: every caller needs a token to
    /// do anything at all, and "not authorized yet" is a state the UI already handles.
    func accessToken(now: Date = Date()) async throws -> String {
        await ensureGrantVisible()
        guard let current = tokens else {
            throw KeymasterSessionError.noGrant
        }

        if refreshInFlight != nil || current.needsRefresh(now: now) {
            do {
                return try await refreshed(from: current).accessToken
            } catch KeymasterSessionError.noGrant {
                if let tokens, !tokens.needsRefresh(now: now) {
                    return tokens.accessToken
                }
                throw KeymasterSessionError.noGrant
            }
        }

        return current.accessToken
    }

    /// A token that is valid now, refreshing even when the clock still considers the current
    /// access token live.
    ///
    /// HTTP 401 names the bearer that request actually sent. A token revoked mid-validity
    /// (`needsRefresh` is still false for up to ~55 minutes) must be spent here or every retry
    /// would carry the same dead credential. A late refusal for a bearer this session has
    /// already replaced is inert: the replacement's rotating refresh token must not be spent.
    /// Concurrent refusals of the same bearer join `refreshed(from:)` so that token is spent
    /// once.
    func refreshIgnoringExpiry(rejected: String) async throws -> String {
        await ensureGrantVisible()
        guard let current = tokens else {
            throw KeymasterSessionError.noGrant
        }
        guard current.accessToken == rejected else {
            return current.accessToken
        }
        do {
            return try await refreshed(from: current).accessToken
        } catch KeymasterSessionError.noGrant {
            if let tokens, tokens.accessToken != rejected {
                return tokens.accessToken
            }
            throw KeymasterSessionError.noGrant
        }
    }

    private func refreshed(from current: KeymasterTokens) async throws -> KeymasterTokens {
        // A second caller during a refresh joins the one already running. Two concurrent
        // refreshes would each spend the same rotating token, and the loser's replacement
        // would be the one Spotify has already invalidated. The in-flight task is the
        // commit, not just the network call, so joiners observe the same persisted grant
        // or `KeymasterSessionError` as the owner.
        if let refreshInFlight {
            do {
                return try await refreshInFlight.value
            } catch is CancellationError {
                throw KeymasterSessionError.noGrant
            }
        }

        let startedAt = generation
        let current = current
        let task = Task {
            try await self.commitRefresh(from: current, startedAt: startedAt)
        }
        refreshInFlight = task
        // Only if the slot still holds *this* run. `adopt` and `clear` both empty it, and a
        // later refresh can have filled it again by the time this one unwinds — clearing that
        // one would let a second refresh start against the same rotating token, which is the
        // race the single-flight exists to prevent.
        defer {
            if refreshInFlight == task {
                refreshInFlight = nil
            }
        }
        return try await task.value
    }

    private func commitRefresh(from current: KeymasterTokens, startedAt: Int) async throws -> KeymasterTokens {
        let renewed: KeymasterTokens
        do {
            renewed = try await refresher(current.refreshToken)
        } catch KeymasterAuthError.grantRevoked {
            // Nothing to retry: this refresh token is dead and every later attempt spends the
            // same one. Left in place it fails forever and survives relaunch, because the
            // session file outlives the process — so forgetting it here is the whole fix for
            // the loop, and the announcement is what gets the user back to a sign-in.
            //
            // Guarded like the success path below: a logout during the network call already
            // cleared this grant, and a sign-in behind it may have adopted a *good* one. The
            // revocation belongs to the token this run spent, not to whatever holds the slot
            // now.
            guard startedAt == generation else {
                throw KeymasterSessionError.noGrant
            }

            guard await clearIfCurrent(startedAt: startedAt) else {
                throw KeymasterSessionError.noGrant
            }
            announceRevocation()
            throw KeymasterSessionError.grantRevoked
        } catch {
            // Adopt, logout, or a newer refresh already owns the slot; a cancelled or
            // transient failure from this spend must not be reported as the replacement's.
            guard startedAt == generation else {
                throw KeymasterSessionError.noGrant
            }
            throw error
        }

        // Back on the actor. A logout that landed during the network call already cleared the
        // grant, so this result belongs to an account that is gone — persisting it would
        // recreate the session file behind logout's back.
        guard startedAt == generation else {
            throw KeymasterSessionError.noGrant
        }

        // Only the initial exchange carries the username, so a refresh that omits it must not
        // blank the stored one.
        var merged = renewed
        if merged.username.isEmpty {
            merged.username = current.username
        }
        merged.requiresReauthentication = current.requiresReauthentication

        do {
            let receipt = persistence.submitSave(merged)
            let result = await receipt.value()
            try result.get()
        } catch {
            guard startedAt == generation else {
                throw KeymasterSessionError.noGrant
            }
            throw error
        }
        guard startedAt == generation else {
            throw KeymasterSessionError.noGrant
        }
        tokens = merged
        return merged
    }

    /// Clears a revoked grant only if the refresh that discovered the revocation still owns the
    /// account generation. The generation check before the first await prevents an old refresh
    /// from signing out a newer interactive grant.
    private func clearIfCurrent(startedAt: Int) async -> Bool {
        guard generation == startedAt else { return false }
        await clear()
        return generation == (startedAt &+ 1)
    }

    /// Waits for the newest sign-in save without creating an unowned task. `adopt` submits its
    /// worker operation before its first await, so this only waits for the receipt already owned
    /// by the actor and cannot let a token refresh race an unpersisted grant.
    private func waitForAdoption() async {
        while let completion = adoptionCompletion {
            await completion.value()
        }
    }
}

nonisolated enum KeymasterSessionError: Error, LocalizedError, Equatable {
    case noGrant
    /// The grant was refused as dead and has been discarded. Separate from `noGrant` so a log
    /// says which of the two happened — a grant that never existed, or one that stopped being
    /// accepted mid-session.
    case grantRevoked

    var errorDescription: String? {
        switch self {
        case .noGrant:
            "This Mac has not been authorized for playback yet"
        case .grantRevoked:
            "Session expired, please sign in again"
        }
    }
}
