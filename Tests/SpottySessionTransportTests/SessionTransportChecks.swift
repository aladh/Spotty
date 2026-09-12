import Foundation
import Testing
import SpottyRuntimeContracts
@testable import SpottySessionTransport

@Suite("Session process contract", .timeLimit(.minutes(1)))
struct SessionTransportChecks {
    @Test func wireRoundTripAndBounds() throws {
        let session = UUID()
        let command = SessionCommand(sessionID: session, action: .addToQueue(["spotify:track:synthetic"]))
        let encoded = try SessionWire.encode(SessionWireRequest(id: UUID(), body: .command(command)))
        let decoded = try SessionWire.decode(SessionWireRequest.self, from: encoded)
        guard case let .command(actual) = decoded.body else { Issue.record("Command lost its type"); return }
        #expect(actual == command)
        #expect(throws: SessionTransportError.payloadTooLarge) {
            try SessionWire.decode(SessionWireRequest.self, from: Data(count: SessionWire.maximumBytes + 1))
        }
        #expect(throws: SessionTransportError.invalidPayload) {
            try SessionWire.validate(SessionCommand(sessionID: session, action: .seek(fraction: .nan)))
        }
        #expect(throws: SessionTransportError.invalidPayload) {
            try SessionWire.validate(
                SessionCommand(sessionID: session, action: .addToQueue(Array(repeating: "uri", count: 257))))
        }
        try SessionWire.validate(
            SessionCommand(
                sessionID: session, action: .transfer(.init(id: "known-device", name: "", type: "", isActive: false))))
    }

    @Test func cursorRejectsGapsOldSnapshotsAndReplacementSessions() {
        let session = UUID()
        var cursor = SessionRevisionCursor()
        cursor.reset(to: SessionSnapshot(sessionID: session, revision: 10))
        #expect(cursor.accept(SessionSnapshot(sessionID: session, revision: 10)) == .ignore)
        #expect(cursor.accept(SessionSnapshot(sessionID: session, revision: 9)) == .ignore)
        #expect(cursor.accept(SessionSnapshot(sessionID: session, revision: 12)) == .resynchronize)
        #expect(cursor.revision == 10)
        #expect(cursor.accept(SessionSnapshot(sessionID: session, revision: 11)) == .publish)
        #expect(cursor.accept(SessionSnapshot(sessionID: UUID(), revision: 12)) == .resynchronize)
    }

    @Test func peerIdentityRequiresExactExecutableAndTeam() throws {
        let identity = try SessionPeerIdentity(teamID: "ABCDEFGHIJ", bundleIdentifier: "dev.spotty.app.session")
        #expect(identity.requirement.contains("anchor apple generic"))
        #expect(identity.requirement.contains("certificate leaf[subject.OU] = \"ABCDEFGHIJ\""))
        #expect(identity.requirement.contains("identifier \"dev.spotty.app.session\""))
        #expect(throws: SessionTransportError.invalidPeerIdentity) {
            try SessionPeerIdentity(teamID: "ABCDEFGHIJ", bundleIdentifier: "id\" or true")
        }
        #expect(throws: SessionTransportError.invalidPeerIdentity) {
            try SessionXPCClient(serviceName: "dev.spotty.demo.session", serviceIdentity: identity)
        }
    }

    @Test func anonymousXPCHandshakeAndRevisionGapResynchronize() async throws {
        let runtime = SyntheticSessionRuntime()
        let host = try SessionXPCServiceHost.synthetic(runtime: runtime)
        defer { host.invalidate() }
        let client = try host.makeSyntheticClient()
        let initial = try await client.connect()
        #expect(initial.revision == 1)
        let updates = await client.subscribe()
        await runtime.publish(revision: 3)
        var found = false
        for await event in updates {
            if case let .snapshot(snapshot) = event, snapshot.revision == 3 {
                found = true
                break
            }
        }
        #expect(found)
        #expect(await runtime.snapshotReads >= 2, "A revision gap performs a complete snapshot read")
        await client.disconnect()
    }

    @Test func connectionLossAfterDispatchIsUnknownAndReconnectDoesNotReplay() async throws {
        let runtime = SyntheticSessionRuntime(holdCommands: true)
        let host = try SessionXPCServiceHost.synthetic(runtime: runtime)
        defer { host.invalidate() }
        let client = try host.makeSyntheticClient()
        let snapshot = try await client.connect()
        let command = SessionCommand(sessionID: snapshot.sessionID, action: .addToQueue(["spotify:track:synthetic"]))
        let operation = Task { try await client.submit(command) }
        await runtime.waitForSubmission()
        await client.disconnect()
        do {
            _ = try await operation.value
            Issue.record("A disconnected write must not report success")
        } catch {
            #expect(error as? SessionTransportError == .unknownOutcome(commandID: command.id))
        }
        #expect(await client.unknownOutcomes.map(\.commandID) == [command.id])
        _ = try await client.connect()
        #expect(await runtime.submissionCount == 1)
        await runtime.releaseCommands()
        #expect(await client.unknownOutcomes.first?.disposition == .unknown)
        await client.disconnect()
    }

    @Test func acknowledgedButUnobservedWriteStillBecomesUnknown() async throws {
        let runtime = SyntheticSessionRuntime()
        let host = try SessionXPCServiceHost.synthetic(runtime: runtime)
        defer { host.invalidate() }
        let client = try host.makeSyntheticClient()
        let snapshot = try await client.connect()
        let command = SessionCommand(sessionID: snapshot.sessionID, action: .togglePlayback)
        #expect(try await client.submit(command).disposition == .sent)
        await client.disconnect()
        #expect(await client.unknownOutcomes.map(\.commandID) == [command.id])
    }

    @Test func staleSessionNeverReachesRuntime() async throws {
        let runtime = SyntheticSessionRuntime()
        let host = try SessionXPCServiceHost.synthetic(runtime: runtime)
        defer { host.invalidate() }
        let client = try host.makeSyntheticClient()
        _ = try await client.connect()
        do {
            _ = try await client.submit(SessionCommand(sessionID: UUID(), action: .logout))
            Issue.record("A stale account write was admitted")
        } catch { #expect(error as? SessionTransportError == .staleSession) }
        #expect(await runtime.submissionCount == 0)
        await client.disconnect()
    }

    @Test func replacedSessionStartsFromCompleteSnapshot() async throws {
        let runtime = SyntheticSessionRuntime()
        let host = try SessionXPCServiceHost.synthetic(runtime: runtime)
        defer { host.invalidate() }
        let client = try host.makeSyntheticClient()
        let original = try await client.connect()
        let stream = await client.subscribe()
        let replacement = UUID()
        await runtime.replaceSession(with: replacement)
        for await event in stream {
            if case let .snapshot(snapshot) = event, snapshot.sessionID == replacement { break }
        }
        #expect(await client.currentSnapshot?.revision == 1)
        #expect(await runtime.snapshotReads >= 2)
        do {
            _ = try await client.submit(SessionCommand(sessionID: original.sessionID, action: .togglePlayback))
            Issue.record("Retired session was admitted")
        } catch { #expect(error as? SessionTransportError == .staleSession) }
        await client.disconnect()
    }

    @Test func helperInvalidationClosesAdmissionAndRetainsUnknownOutcome() async throws {
        let runtime = SyntheticSessionRuntime()
        let host = try SessionXPCServiceHost.synthetic(runtime: runtime)
        let client = try host.makeSyntheticClient()
        let snapshot = try await client.connect()
        let command = SessionCommand(sessionID: snapshot.sessionID, action: .togglePlayback)
        _ = try await client.submit(command)
        let stream = await client.subscribe()
        host.invalidate()
        for await event in stream {
            if case let .disconnected(unknown) = event {
                #expect(unknown.map(\.commandID) == [command.id])
                break
            }
        }
        #expect(await client.currentSnapshot == nil)
        do {
            _ = try await client.submit(SessionCommand(sessionID: snapshot.sessionID, action: .next))
            Issue.record("Lost helper still accepted a write")
        } catch { #expect(error as? SessionTransportError == .notConnected) }
        #expect(await runtime.submissionCount == 1)
    }

    @Test func oversizedPostDispatchResultIsUnknownRatherThanRejected() async throws {
        let runtime = SyntheticSessionRuntime(oversizedReceipt: true)
        let host = try SessionXPCServiceHost.synthetic(runtime: runtime)
        defer { host.invalidate() }
        let client = try host.makeSyntheticClient()
        let snapshot = try await client.connect()
        let command = SessionCommand(sessionID: snapshot.sessionID, action: .togglePlayback)
        #expect(try await client.submit(command).disposition == .unknown)
        #expect(await client.unknownOutcomes.map(\.commandID) == [command.id])
        await client.disconnect()
    }

    @Test func observedReceiptRemainsTerminalAfterDisconnection() async throws {
        let runtime = SyntheticSessionRuntime()
        let host = try SessionXPCServiceHost.synthetic(runtime: runtime)
        defer { host.invalidate() }
        let client = try host.makeSyntheticClient()
        let snapshot = try await client.connect()
        let command = SessionCommand(sessionID: snapshot.sessionID, action: .togglePlayback)
        _ = try await client.submit(command)
        let stream = await client.subscribe()
        await runtime.confirm(command)
        for await event in stream {
            if case let .snapshot(value) = event,
                value.receipts.contains(where: { $0.commandID == command.id && $0.disposition == .observedConfirmed })
            {
                break
            }
        }
        await client.disconnect()
        #expect(await client.unknownOutcomes.isEmpty)
    }

    @Test(arguments: [false, true])
    func bothPeersRejectUnexpectedSignature(rejectAtService: Bool) async throws {
        let listener = SignatureTestListener(rejectClient: rejectAtService)
        defer { listener.invalidate() }
        let client = SessionXPCClient(
            endpoint: listener.endpoint,
            peerRequirement: try rejectAtService
                ? SessionPeerIdentity.currentProcessRequirement() : SignatureTestListener.unexpectedIdentity)
        do {
            _ = try await client.connect()
            Issue.record("A peer with the wrong signing identity was accepted")
        } catch { #expect(error as? SessionTransportError == .disconnected) }
        #expect(await client.currentSnapshot == nil)
    }

    @Test func accountReplacementRetiresWritesAndReleasesAdmissionCapacity() async throws {
        let runtime = SyntheticSessionRuntime()
        let host = try SessionXPCServiceHost.synthetic(runtime: runtime)
        defer { host.invalidate() }
        let client = try host.makeSyntheticClient()
        let original = try await client.connect()
        for _ in 0..<SessionWire.maximumPendingRequests {
            _ = try await client.submit(SessionCommand(sessionID: original.sessionID, action: .togglePlayback))
        }
        do {
            _ = try await client.submit(SessionCommand(sessionID: original.sessionID, action: .next))
            Issue.record("Unsettled command admission exceeded its bound")
        } catch { #expect(error as? SessionTransportError == .tooManyRequests) }
        let replacement = UUID()
        let stream = await client.subscribe()
        await runtime.replaceSession(with: replacement)
        for await event in stream {
            if case let .snapshot(snapshot) = event, snapshot.sessionID == replacement { break }
        }
        #expect(await client.unknownOutcomes.count == SessionWire.maximumPendingRequests)
        #expect(
            try await client.submit(SessionCommand(sessionID: replacement, action: .togglePlayback)).disposition
                == .sent)
        await client.disconnect()
    }

    @Test func accountReplacementSettlesPendingWriteBeforeLateResponse() async throws {
        let runtime = SyntheticSessionRuntime(holdCommands: true)
        let host = try SessionXPCServiceHost.synthetic(runtime: runtime)
        defer { host.invalidate() }
        let client = try host.makeSyntheticClient()
        let original = try await client.connect()
        let command = SessionCommand(sessionID: original.sessionID, action: .togglePlayback)
        let operation = Task { try await client.submit(command) }
        await runtime.waitForSubmission()
        await runtime.replaceSession(with: UUID())
        do {
            _ = try await operation.value
            Issue.record("Retired write returned a known outcome")
        } catch { #expect(error as? SessionTransportError == .unknownOutcome(commandID: command.id)) }
        await runtime.releaseCommands()
        #expect(await client.unknownOutcomes.map(\.commandID) == [command.id])
        await client.disconnect()
    }

    @Test func snapshotUnknownSurvivesReceiptWindowAndDoesNotDuplicate() async throws {
        let runtime = SyntheticSessionRuntime()
        let host = try SessionXPCServiceHost.synthetic(runtime: runtime)
        defer { host.invalidate() }
        let client = try host.makeSyntheticClient()
        let snapshot = try await client.connect()
        let command = SessionCommand(sessionID: snapshot.sessionID, action: .togglePlayback)
        _ = try await client.submit(command)
        let stream = await client.subscribe()
        await runtime.finish(command, disposition: .unknown)
        for await event in stream {
            if case let .snapshot(value) = event, value.revision == 2 { break }
        }
        let cleared = await client.subscribe()
        await runtime.clearReceipts()
        for await event in cleared {
            if case let .snapshot(value) = event, value.revision == 3 {
                #expect(value.receipts.isEmpty)
                break
            }
        }
        await client.disconnect()
        #expect(await client.unknownOutcomes.map(\.commandID) == [command.id])
        #expect(await client.unknownOutcomes.first?.message == "The command outcome could not be confirmed.")
    }
}

private actor SyntheticSessionRuntime: SessionRuntimeServing {
    private var value = SessionSnapshot(sessionID: UUID(), revision: 1, capabilities: [.transport, .queueAppend])
    private var subscriptions: [UUID: AsyncStream<SessionSnapshot>.Continuation] = [:]
    private let holdCommands: Bool
    private let oversizedReceipt: Bool
    private var commandGates: [CheckedContinuation<Void, Never>] = []
    private var submissionWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var submissionCount = 0
    private(set) var snapshotReads = 0

    init(holdCommands: Bool = false, oversizedReceipt: Bool = false) {
        self.holdCommands = holdCommands
        self.oversizedReceipt = oversizedReceipt
    }

    func snapshot() -> SessionSnapshot {
        snapshotReads += 1
        return value
    }

    func submit(_ command: SessionCommand) async -> SessionCommandReceipt {
        submissionCount += 1
        let waiters = submissionWaiters
        submissionWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if holdCommands { await withCheckedContinuation { commandGates.append($0) } }
        return SessionCommandReceipt(
            commandID: command.id, sessionID: command.sessionID, disposition: .sent,
            message: oversizedReceipt ? String(repeating: "x", count: SessionWire.maximumBytes + 1) : nil)
    }

    func subscribe() -> AsyncStream<SessionSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<SessionSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(8))
        subscriptions[id] = continuation
        continuation.yield(value)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscription(id) }
        }
        return stream
    }

    func publish(revision: UInt64) {
        value.revision = revision
        for subscriber in subscriptions.values { subscriber.yield(value) }
    }

    func replaceSession(with id: UUID) {
        value = SessionSnapshot(sessionID: id, revision: 1)
        for subscriber in subscriptions.values { subscriber.yield(value) }
    }

    func confirm(_ command: SessionCommand) {
        finish(command, disposition: .observedConfirmed)
    }

    func finish(_ command: SessionCommand, disposition: SessionCommandDisposition) {
        value.receipts = [.init(commandID: command.id, sessionID: command.sessionID, disposition: disposition)]
        publish(revision: value.revision + 1)
    }

    func clearReceipts() {
        value.receipts = []
        publish(revision: value.revision + 1)
    }

    func waitForSubmission() async {
        guard submissionCount == 0 else { return }
        await withCheckedContinuation { submissionWaiters.append($0) }
    }

    func releaseCommands() {
        let gates = commandGates
        commandGates.removeAll()
        gates.forEach { $0.resume() }
    }

    private func removeSubscription(_ id: UUID) { subscriptions.removeValue(forKey: id) }
}

/// A deliberately unrelated peer on an anonymous endpoint. It proves signature enforcement on
/// each direction of the real transport without connecting to a live service or account.
private final class SignatureTestListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    static let unexpectedIdentity = "identifier \"dev.spotty.untrusted.synthetic\""
    private let listener = NSXPCListener.anonymous()
    private let rejectClient: Bool
    private let lock = NSLock()
    private var connections: [NSXPCConnection] = []

    var endpoint: NSXPCListenerEndpoint { listener.endpoint }

    init(rejectClient: Bool) {
        self.rejectClient = rejectClient
        super.init()
        listener.delegate = self
        listener.resume()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        if rejectClient { connection.setCodeSigningRequirement(Self.unexpectedIdentity) }
        connection.exportedInterface = NSXPCInterface(with: SessionXPCRequests.self)
        connection.exportedObject = SignatureTestReceiver()
        lock.withLock { connections.append(connection) }
        connection.resume()
        return true
    }

    func invalidate() {
        listener.invalidate()
        let retained = lock.withLock { connections }
        for connection in retained { connection.invalidate() }
    }
}

private final class SignatureTestReceiver: NSObject, SessionXPCRequests {
    func exchange(_ data: Data, reply: @escaping @Sendable (Data) -> Void) {
        guard let request = try? SessionWire.decode(SessionWireRequest.self, from: data),
            let response = try? SessionWire.encode(
                SessionWireResponse(
                    id: request.id, body: .snapshot(.init(sessionID: UUID(), revision: 1))))
        else { reply(Data()); return }
        reply(response)
    }
}
