import Foundation
import Network
import Testing
@testable import SpottyGateway

@Suite("Loopback callback lifetimes")
@MainActor
struct LoopbackLifecycleTests {
    enum Termination: CaseIterable { case stop, cancellation, timeout, callback }

    @Test(arguments: Termination.allCases)
    func terminationClosesAcceptedIncompleteRequests(termination: Termination) async throws {
        let server = LoopbackCallbackServer()
        defer { Task { await server.stop() } }
        let port = try await server.start()
        let peer = LoopbackPeer(port: port)
        defer { peer.cancel() }
        try await peer.send("GET /login?code=unfinished")
        try await requireLoopback { await server.activeConnectionCount == 1 }

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
        try await requireLoopback { peer.closed }
        #expect(await server.activeConnectionCount == 0)
    }

    @Test
    func stoppingBeforeWaitingRetainsCancellationAndCannotRestart() async throws {
        let server = LoopbackCallbackServer()
        defer { Task { await server.stop() } }
        _ = try await server.start()
        await server.stop()
        await #expect(throws: CancellationError.self) { try await server.waitForCallback() }
        await #expect(throws: CancellationError.self) { try await server.waitForCallback() }
        await #expect(throws: LoopbackCallbackServer.ServerError.self) { try await server.start() }
    }

    @Test
    func unrelatedConnectionFailureDoesNotConsumeTheCallback() async throws {
        let server = LoopbackCallbackServer()
        defer { Task { await server.stop() } }
        let port = try await server.start()
        let peer = LoopbackPeer(port: port)
        defer { peer.cancel() }
        try await peer.send("GET /login?code=unfinished")
        try await requireLoopback { await server.activeConnectionCount == 1 }
        // A complete TCP stream with no complete HTTP request is only this peer's failure.
        try await peer.finish()
        try await requireLoopback { peer.closed }

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

@MainActor
private func requireLoopback(_ condition: () async -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(10)
    while clock.now < deadline {
        if await condition() { return }
        await Task.yield()
    }
    struct TimedOut: Error {}
    throw TimedOut()
}
