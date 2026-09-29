import SpottyTestSupport
import Foundation
import Network
import Testing
@testable import SpottyGateway

@Suite("Loopback callback lifetimes")
@MainActor
struct LoopbackLifecycleTests {
    enum Termination: CaseIterable { case stop, cancellation, timeout, callback }

    @Test
    func incompleteRequestsAreBoundedAndExpireWithoutEndingSignIn() async throws {
        let clock = HarnessClock.scheduled()
        let server = LoopbackCallbackServer(expectedState: "synthetic", maximumConnections: 2, requestClock: clock)
        defer { Task { await server.stop() }; clock.releaseAll() }
        let port = try await server.start()
        let first = LoopbackPeer(port: port)
        let second = LoopbackPeer(port: port)
        defer { first.cancel(); second.cancel() }
        try await first.send("GET /login?code=unfinished")
        try await second.send("GET /login?code=unfinished")
        try await requireEventually(description: "loopback socket transition") {
            await server.activeConnectionCount == 2
        }
        let overflow = LoopbackPeer(port: port)
        defer { overflow.cancel() }
        try await requireEventually(description: "loopback socket transition") { overflow.closed }
        #expect(await server.activeConnectionCount == 2)
        try await requireEventually(description: "loopback socket transition") { clock.waiterCount == 2 }
        clock.advance(seconds: 9)
        #expect(clock.waiterCount == 2, "incomplete requests keep their full read budget")
        clock.advance(seconds: 1)
        try await requireEventually(description: "loopback socket transition") { first.closed && second.closed }
        #expect(await server.activeConnectionCount == 0)

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(
            from: URL(string: "http://127.0.0.1:\(port)/login?code=accepted&state=synthetic")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let callback = try await server.waitForCallback(timeout: .seconds(5))
        #expect(callback.queryItems?.first { $0.name == "code" }?.value == "accepted")
        try await requireEventually(description: "loopback socket transition") { clock.waiterCount == 0 }
    }

    @Test
    func releasingListenerClosesIncompletePeersAndDeadlines() async throws {
        let clock = HarnessClock.parked()
        var server: LoopbackCallbackServer? = LoopbackCallbackServer(expectedState: "synthetic", requestClock: clock)
        weak let released = server
        defer {
            if let server { Task { await server.stop() } }
            clock.releaseAll()
        }
        let port = try await server!.start()
        let peer = LoopbackPeer(port: port)
        defer { peer.cancel() }
        try await peer.send("GET /login?code=unfinished")
        try await requireEventually(description: "loopback socket transition") {
            await server?.activeConnectionCount == 1
        }
        server = nil
        try await requireEventually(description: "loopback socket transition") { released == nil }
        try await requireEventually(description: "loopback socket transition") { peer.closed }
        #expect(clock.waiterCount == 0)
    }

    @Test(arguments: [false, true])
    func invalidStateDoesNotConsumeASuccessOrDenial(denied: Bool) async throws {
        let server = LoopbackCallbackServer(expectedState: "synthetic")
        defer { Task { await server.stop() } }
        let port = try await server.start()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for query in ["code=stray", "code=stray&state=other", "error=access_denied&state=other"] {
            let (_, response) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/login?\(query)")!)
            #expect((response as? HTTPURLResponse)?.statusCode == 400)
        }
        let query = denied ? "error=access_denied" : "code=accepted"
        let (_, response) = try await session.data(
            from: URL(string: "http://127.0.0.1:\(port)/login?\(query)&state=synthetic")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        // A matched callback may arrive before the caller starts waiting.
        let callback = try await server.waitForCallback(timeout: .seconds(5))
        if denied {
            #expect(throws: KeymasterAuthError.authorizationDenied) {
                try KeymasterAuth.authorizationCode(from: callback, expectedState: "synthetic")
            }
        } else {
            #expect(try KeymasterAuth.authorizationCode(from: callback, expectedState: "synthetic") == "accepted")
        }
        #expect(await server.activeConnectionCount == 0)
    }

    @Test(arguments: Termination.allCases)
    func terminationClosesAcceptedIncompleteRequests(termination: Termination) async throws {
        let server = LoopbackCallbackServer(expectedState: "synthetic")
        defer { Task { await server.stop() } }
        let port = try await server.start()
        let peer = LoopbackPeer(port: port)
        defer { peer.cancel() }
        try await peer.send("GET /login?code=unfinished")
        try await requireEventually(description: "loopback socket transition") {
            await server.activeConnectionCount == 1
        }

        let waiting = Task { try await server.waitForCallback(timeout: termination == .timeout ? .zero : nil) }
        defer { waiting.cancel() }
        switch termination {
        case .stop: await server.stop()
        case .cancellation: waiting.cancel()
        case .timeout: break
        case .callback:
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let (_, response) = try await session.data(
                from: URL(string: "http://127.0.0.1:\(port)/login?code=accepted&state=synthetic")!)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
        }
        let result = await waiting.result
        if termination == .callback {
            #expect(try result.get().queryItems?.first { $0.name == "code" }?.value == "accepted")
        } else {
            #expect(throws: (any Error).self) { try result.get() }
        }
        try await requireEventually(description: "loopback socket transition") { peer.closed }
        #expect(await server.activeConnectionCount == 0)
    }

    @Test
    func stoppingBeforeWaitingRetainsCancellationAndCannotRestart() async throws {
        let server = LoopbackCallbackServer(expectedState: "synthetic")
        defer { Task { await server.stop() } }
        _ = try await server.start()
        await server.stop()
        await #expect(throws: CancellationError.self) { try await server.waitForCallback() }
        await #expect(throws: CancellationError.self) { try await server.waitForCallback() }
        await #expect(throws: LoopbackCallbackServer.ServerError.self) { try await server.start() }
    }

    @Test
    func unrelatedConnectionFailureDoesNotConsumeTheCallback() async throws {
        let server = LoopbackCallbackServer(expectedState: "synthetic")
        defer { Task { await server.stop() } }
        let port = try await server.start()
        let peer = LoopbackPeer(port: port)
        defer { peer.cancel() }
        try await peer.send("GET /login?code=unfinished")
        try await requireEventually(description: "loopback socket transition") {
            await server.activeConnectionCount == 1
        }
        // A complete TCP stream with no complete HTTP request is only this peer's failure.
        try await peer.finish()
        try await requireEventually(description: "loopback socket transition") { peer.closed }

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(
            from: URL(string: "http://127.0.0.1:\(port)/login?code=accepted&state=synthetic")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let callback = try await server.waitForCallback(timeout: .seconds(5))
        #expect(callback.queryItems?.first { $0.name == "code" }?.value == "accepted")
        #expect(await server.activeConnectionCount == 0)
    }
}

// The shared HTTP harness cannot represent an accepted socket with an incomplete request.
// This peer uses only the test server's ephemeral loopback port and observes remote closure.
@MainActor
private final class LoopbackPeer {
    private let connection: NWConnection
    private(set) var closed = false

    init(port: UInt16) {
        connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] _, _, complete, error in
            Task { @MainActor in self?.closed = complete || error != nil }
        }
    }

    func send(_ text: String) async throws {
        try await send(Data(text.utf8), complete: false)
    }

    func finish() async throws {
        try await send(nil, complete: true)
    }

    private func send(_ data: Data?, complete: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data, contentContext: complete ? .finalMessage : .defaultMessage, isComplete: complete,
                completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
        }
    }

    func cancel() { connection.cancel() }
}
