import Foundation
import SpottyDomain
import SpottyTestSupport
import Testing
@testable import SpottyRuntimeTestSupport
@testable import SpottySessionRuntime

/// Owns controlled command dependencies and their worker lifetimes. Scenario setup, observations,
/// and expected reducer/persistence outcomes belong to each test.
@SessionRuntimeActor
final class CommandRuntimeFixture {
    enum Lane { case local, remote }

    struct Command {
        let id: UUID
        let kind: PlaybackCommandKind
        let settlement: PlaybackEffectSettlement
    }

    let engine = HarnessEngine()
    let remote = HarnessRemote()
    let account = HarnessAccount()
    let engineGate = HarnessEngineGate()
    let remoteResponses: HarnessResponseGate<Void>
    let preferences: HarnessPreferences
    let runtime: PlaybackSessionRuntime
    private var settlements: [PlaybackEffectSettlement] = []

    fileprivate init(preferences: HarnessPreferences, remoteCancellation: HarnessResponseGate<Void>.Cancellation) {
        self.preferences = preferences
        remoteResponses = HarnessResponseGate(cancellation: remoteCancellation)
        engine.onExecute = { [engineGate] _ in engineGate.enter() }
        remote.onSend = { [remoteResponses] _, _, _ in try await remoteResponses.wait() }
        runtime = PlaybackSessionRuntime(
            environment: HarnessEnvironment.make(
                engine: engine, remote: remote, account: account, preferences: preferences))
    }

    /// Admission and exact settlement capture happen in one actor turn. Refusal/duplicate checks
    /// call the runtime directly instead of mistaking an older pending command for new admission.
    func capture(
        _ kind: PlaybackCommandKind,
        sourceLocation: SourceLocation = #_sourceLocation,
        performing action: () -> Void
    ) throws -> Command {
        let previous = runtime.state.pendingCommands[kind]?.id
        action()
        let admitted = try #require(runtime.state.pendingCommands[kind], sourceLocation: sourceLocation)
        try #require(admitted.id != previous, "The action must admit a new command", sourceLocation: sourceLocation)
        let settlement = try #require(
            runtime.effects.settlement(of: .command(admitted.id)), sourceLocation: sourceLocation)
        settlements.append(settlement)
        return Command(id: admitted.id, kind: kind, settlement: settlement)
    }

    /// Entry numbers refer to dependency calls, not command IDs or playback ownership. In
    /// particular, a second sequential request must prove its own entry before receiving a reply.
    func requireDispatch(
        through lane: Lane, number: Int = 1,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try #require(number > 0, sourceLocation: sourceLocation)
        try await requireEventually(
            description: "Command enters dependency call \(number)", sourceLocation: sourceLocation
        ) {
            switch lane {
            case .local: engineGate.enteredCount == number
            case .remote: remoteResponses.requestCount == number && remoteResponses.waiterCount > 0
            }
        }
    }

    /// Replies are FIFO dependency responses. The caller separately joins a captured command;
    /// a failed response can still settle successfully after an authoritative engine observation.
    func reply(
        through lane: Lane, number: Int = 1, success: Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await requireDispatch(through: lane, number: number, sourceLocation: sourceLocation)
        switch lane {
        case .local: engineGate.finish(with: success ? .ok : .error)
        case .remote: remoteResponses.resolve(success ? .success(()) : .failure(HarnessFailure.unavailable))
        }
    }

    fileprivate func cleanUp(closing: () -> Void) async {
        let cancelled = runtime.effects.cancelAccountScoped()
        // Terminal closure precedes every join, including responses that ignore cancellation.
        engineGate.close()
        remoteResponses.close()
        closing()
        for settlement in settlements { await settlement.wait() }
        for settlement in cancelled.values { await settlement.wait() }
        await runtime.shutdownForTermination()
    }
}

@SessionRuntimeActor
func withCommandRuntime(
    preferences: HarnessPreferences = HarnessPreferences(),
    remoteCancellation: HarnessResponseGate<Void>.Cancellation = .cooperative,
    closing: () -> Void = {},
    _ body: (CommandRuntimeFixture) async throws -> Void
) async throws {
    let fixture = CommandRuntimeFixture(preferences: preferences, remoteCancellation: remoteCancellation)
    do {
        try await body(fixture)
    } catch {
        await fixture.cleanUp(closing: closing)
        throw error
    }
    await fixture.cleanUp(closing: closing)
}
